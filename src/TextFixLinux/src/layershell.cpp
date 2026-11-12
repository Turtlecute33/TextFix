// SPDX-License-Identifier: GPL-3.0-only
#include "layershell.h"
#include <wayland-client.h>
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <poll.h>
#include <sys/eventfd.h>
#include <sys/mman.h>
#include <thread>
#include <unistd.h>
#include <vector>

namespace {
// wlr-layer-shell-unstable-v1, version 1, written out by hand: the build then needs no
// wayland-scanner and no protocol files. The names, the signatures and the order of the
// requests are those of the protocol. A mistake here gives a protocol error on this connection
// only; the connection of Qt is a different one.
const wl_interface *noTypes[] = {nullptr, nullptr, nullptr, nullptr};

const wl_message layerSurfaceRequests[] = {
    {"set_size", "uu", noTypes},
    {"set_anchor", "u", noTypes},
    {"set_exclusive_zone", "i", noTypes},
    {"set_margin", "iiii", noTypes},
    {"set_keyboard_interactivity", "u", noTypes},
    {"get_popup", "o", noTypes},
    {"ack_configure", "u", noTypes},
    {"destroy", "", noTypes},
};
const wl_message layerSurfaceEvents[] = {
    {"configure", "uuu", noTypes},
    {"closed", "", noTypes},
};
const wl_interface layerSurfaceInterface = {"zwlr_layer_surface_v1", 1, 8, layerSurfaceRequests, 2, layerSurfaceEvents};

const wl_interface *getLayerSurfaceTypes[] = {
    &layerSurfaceInterface, &wl_surface_interface, &wl_output_interface, nullptr, nullptr};
const wl_message layerShellRequests[] = {{"get_layer_surface", "no?ous", getLayerSurfaceTypes}};
const wl_interface layerShellInterface = {"zwlr_layer_shell_v1", 1, 1, layerShellRequests, 0, nullptr};

enum : uint32_t { SetSize = 0, SetAnchor = 1, SetMargin = 3, SetKeyboardInteractivity = 4, AckConfigure = 6, Destroy = 7 };
constexpr uint32_t OverlayLayer = 3;
constexpr uint32_t AnchorBottom = 2;

struct LayerSurfaceListener {
    void (*configure)(void *data, wl_proxy *layer, uint32_t serial, uint32_t width, uint32_t height);
    void (*closed)(void *data, wl_proxy *layer);
};

struct Buffer {
    wl_buffer *buffer = nullptr;
    uint32_t *pixels = nullptr;
    bool busy = false;
};

struct Command {
    enum Kind { Start, Promote, Hide, Quit } kind;
    double time = 0;
    bool reduced = false;
};
}

struct LayerShellPill::State {
    // Set up by the main thread before the thread starts.
    wl_display *display = nullptr;
    wl_registry *registry = nullptr;
    wl_compositor *compositor = nullptr;
    uint32_t compositorVersion = 0;
    wl_shm *shm = nullptr;
    wl_proxy *layerShell = nullptr;
    int wake = -1;
    std::thread thread;
    std::atomic<bool> alive{false};

    std::mutex mutex;
    std::vector<Command> commands;

    // Owned by the thread.
    wl_surface *surface = nullptr;
    wl_proxy *layer = nullptr;
    wl_callback *frame = nullptr;
    bool configured = false;
    bool visible = false;
    // The compositor sends the right scale when the surface is on an output. Until then 2 is
    // sharp on both kinds of screen.
    int scale = 2;
    int bufferScale = 0;
    int width = 0, height = 0;
    void *memory = nullptr;
    size_t memorySize = 0;
    Buffer buffers[2];
    PillScene::Timeline timeline;
    PillScene::Frame scene;

    void post(Command command) {
        {
            std::lock_guard<std::mutex> lock(mutex);
            commands.push_back(command);
        }
        const uint64_t one = 1;
        if (write(wake, &one, sizeof one) < 0) {}
    }

    void run() {
        pollfd fds[2] = {{wl_display_get_fd(display), POLLIN, 0}, {wake, POLLIN, 0}};
        for (;;) {
            while (wl_display_prepare_read(display) != 0) wl_display_dispatch_pending(display);
            wl_display_flush(display);
            if (poll(fds, 2, -1) < 0) {
                wl_display_cancel_read(display);
                if (errno == EINTR) continue;
                break;
            }
            if (fds[0].revents & POLLIN) {
                if (wl_display_read_events(display) < 0) break;
            } else {
                wl_display_cancel_read(display);
            }
            if (fds[0].revents & (POLLERR | POLLHUP)) break;
            if (wl_display_dispatch_pending(display) < 0) break;
            if (fds[1].revents & POLLIN) {
                uint64_t count;
                if (read(wake, &count, sizeof count) < 0) {}
                std::vector<Command> pending;
                {
                    std::lock_guard<std::mutex> lock(mutex);
                    pending.swap(commands);
                }
                for (const Command &command : pending) {
                    if (command.kind == Command::Quit) {
                        destroySurface();
                        wl_display_flush(display);
                        return;
                    }
                    handle(command);
                }
            }
        }
        // The compositor went away or refused a request. TextFix shows notifications from now on.
        alive = false;
    }

    void handle(const Command &command) {
        switch (command.kind) {
        case Command::Start:
            // A start while the pill leaves brings it back. A start while it is up does nothing.
            if (visible && !timeline.hidingAt) break;
            timeline = {};
            timeline.shownAt = command.time;
            timeline.reduced = command.reduced;
            visible = true;
            if (!surface) createSurface();
            else if (configured && !frame) draw();
            break;
        case Command::Promote:
            if (!visible || timeline.workingAt) break;
            timeline.workingAt = command.time;
            if (configured && !frame) draw();
            break;
        case Command::Hide:
            if (!visible || timeline.hidingAt) break;
            timeline.hidingAt = command.time;
            if (!configured) {
                destroySurface();
                visible = false;
            } else if (!frame) {
                draw();
            }
            break;
        case Command::Quit:
            break;
        }
    }

    void createSurface() {
        surface = wl_compositor_create_surface(compositor);
#ifdef WL_SURFACE_PREFERRED_BUFFER_SCALE_SINCE_VERSION
        static const wl_surface_listener surfaceListener = {&enter, &leave, &preferredScale, &preferredTransform};
        wl_surface_add_listener(surface, &surfaceListener, this);
#endif
        // An empty input region: clicks go to the window below.
        wl_region *region = wl_compositor_create_region(compositor);
        wl_surface_set_input_region(surface, region);
        wl_region_destroy(region);

        // No output: the compositor puts it on the output that has the focus.
        layer = wl_proxy_marshal_flags(layerShell, 0, &layerSurfaceInterface, wl_proxy_get_version(layerShell), 0,
                                       nullptr, surface, nullptr, OverlayLayer, "textfix");
        static const LayerSurfaceListener layerListener = {&configure, &closed};
        wl_proxy_add_listener(layer, reinterpret_cast<void (**)(void)>(const_cast<LayerSurfaceListener *>(&layerListener)), this);
        const uint32_t version = wl_proxy_get_version(layer);
        wl_proxy_marshal_flags(layer, SetSize, nullptr, version, 0,
                               uint32_t(PillScene::SurfaceWidth), uint32_t(PillScene::SurfaceHeight));
        wl_proxy_marshal_flags(layer, SetAnchor, nullptr, version, 0, AnchorBottom);
        wl_proxy_marshal_flags(layer, SetMargin, nullptr, version, 0,
                               int32_t(0), int32_t(0), int32_t(PillScene::BottomGap - PillScene::Margin), int32_t(0));
        wl_proxy_marshal_flags(layer, SetKeyboardInteractivity, nullptr, version, 0, uint32_t(0));
        wl_surface_commit(surface);
        configured = false;
    }

    void destroySurface() {
        if (frame) wl_callback_destroy(frame);
        frame = nullptr;
        if (layer) wl_proxy_marshal_flags(layer, Destroy, nullptr, wl_proxy_get_version(layer), WL_MARSHAL_FLAG_DESTROY);
        layer = nullptr;
        if (surface) wl_surface_destroy(surface);
        surface = nullptr;
        configured = false;
        for (Buffer &buffer : buffers) buffer.busy = false;
    }

    void draw() {
        if (!surface || !configured) return;
        const double now = PillScene::now();
        PillScene::frameAt(now, timeline, scene);
        if (scene.finished || (bufferScale != scale && !allocate())) {
            destroySurface();
            visible = false;
            return;
        }
        Buffer *buffer = !buffers[0].busy ? &buffers[0] : !buffers[1].busy ? &buffers[1] : nullptr;
        if (buffer) {
            double stageScale, opacity;
            PillScene::stage(now, timeline, stageScale, opacity);
            PillScene::render(scene, stageScale, opacity, buffer->pixels, width, height, scale);
            wl_surface_set_buffer_scale(surface, scale);
            wl_surface_attach(surface, buffer->buffer, 0, 0);
            wl_surface_damage_buffer(surface, 0, 0, width, height);
            buffer->busy = true;
        }
        // A still pill needs no more frames. Promote and hide start them again.
        if (!scene.settled || !buffer) {
            static const wl_callback_listener frameListener = {&frameDone};
            frame = wl_surface_frame(surface);
            wl_callback_add_listener(frame, &frameListener, this);
        }
        wl_surface_commit(surface);
    }

    bool allocate() {
        releaseBuffers();
        const int w = PillScene::SurfaceWidth * scale, h = PillScene::SurfaceHeight * scale;
        const size_t one = size_t(w) * size_t(h) * 4;
        const int fd = memfd_create("textfix-pill", MFD_CLOEXEC);
        if (fd < 0) return false;
        if (ftruncate(fd, off_t(one * 2)) < 0) {
            close(fd);
            return false;
        }
        void *mapped = mmap(nullptr, one * 2, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (mapped == MAP_FAILED) {
            close(fd);
            return false;
        }
        memory = mapped;
        memorySize = one * 2;
        wl_shm_pool *pool = wl_shm_create_pool(shm, fd, int32_t(memorySize));
        static const wl_buffer_listener bufferListener = {&released};
        for (int i = 0; i < 2; ++i) {
            buffers[i].buffer = wl_shm_pool_create_buffer(pool, int32_t(one) * i, w, h, w * 4, WL_SHM_FORMAT_ARGB8888);
            buffers[i].pixels = reinterpret_cast<uint32_t *>(static_cast<char *>(memory) + one * size_t(i));
            buffers[i].busy = false;
            wl_buffer_add_listener(buffers[i].buffer, &bufferListener, &buffers[i]);
        }
        wl_shm_pool_destroy(pool);
        close(fd);
        bufferScale = scale;
        width = w;
        height = h;
        return true;
    }

    void releaseBuffers() {
        for (Buffer &buffer : buffers) {
            if (buffer.buffer) wl_buffer_destroy(buffer.buffer);
            buffer = {};
        }
        if (memory) munmap(memory, memorySize);
        memory = nullptr;
        memorySize = 0;
        bufferScale = 0;
    }

    void disconnect() {
        releaseBuffers();
        if (layerShell) wl_proxy_destroy(layerShell);
        if (shm) wl_shm_destroy(shm);
        if (compositor) wl_compositor_destroy(compositor);
        if (registry) wl_registry_destroy(registry);
        if (display) wl_display_disconnect(display);
        if (wake >= 0) close(wake);
        layerShell = nullptr;
        shm = nullptr;
        compositor = nullptr;
        registry = nullptr;
        display = nullptr;
        wake = -1;
    }

    // ---- listeners ----

    static void global(void *data, wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
        auto *d = static_cast<State *>(data);
        if (std::strcmp(interface, wl_compositor_interface.name) == 0 && version >= 4) {
#ifdef WL_SURFACE_PREFERRED_BUFFER_SCALE_SINCE_VERSION
            d->compositorVersion = std::min(version, 6u);
#else
            d->compositorVersion = std::min(version, 5u);
#endif
            d->compositor = static_cast<wl_compositor *>(
                wl_registry_bind(registry, name, &wl_compositor_interface, d->compositorVersion));
        } else if (std::strcmp(interface, wl_shm_interface.name) == 0) {
            d->shm = static_cast<wl_shm *>(wl_registry_bind(registry, name, &wl_shm_interface, 1));
        } else if (std::strcmp(interface, layerShellInterface.name) == 0) {
            d->layerShell = static_cast<wl_proxy *>(wl_registry_bind(registry, name, &layerShellInterface, 1));
        }
    }
    static void globalRemove(void *, wl_registry *, uint32_t) {}

    static void configure(void *data, wl_proxy *layer, uint32_t serial, uint32_t, uint32_t) {
        auto *d = static_cast<State *>(data);
        wl_proxy_marshal_flags(layer, AckConfigure, nullptr, wl_proxy_get_version(layer), 0, serial);
        if (d->configured) return;
        d->configured = true;
        if (!d->frame) d->draw();
    }
    static void closed(void *data, wl_proxy *) {
        auto *d = static_cast<State *>(data);
        d->destroySurface();
        d->visible = false;
    }
    static void frameDone(void *data, wl_callback *callback, uint32_t) {
        auto *d = static_cast<State *>(data);
        wl_callback_destroy(callback);
        d->frame = nullptr;
        d->draw();
    }
    static void released(void *data, wl_buffer *) { static_cast<Buffer *>(data)->busy = false; }
    static void enter(void *, wl_surface *, wl_output *) {}
    static void leave(void *, wl_surface *, wl_output *) {}
    static void preferredScale(void *data, wl_surface *, int32_t factor) {
        auto *d = static_cast<State *>(data);
        if (factor < 1 || factor > 4 || factor == d->scale) return;
        d->scale = factor;
        if (d->configured && !d->frame) d->draw();
    }
    static void preferredTransform(void *, wl_surface *, uint32_t) {}
};

LayerShellPill::LayerShellPill() : d(std::make_unique<State>()) {
    // Without this, libwayland tries wayland-0, which can be a different session.
    if (!std::getenv("WAYLAND_DISPLAY")) return;
    // Made after QGuiApplication: if TextFix got its connection as WAYLAND_SOCKET, Qt has used it
    // and this connects by name.
    d->display = wl_display_connect(nullptr);
    if (!d->display) return;
    d->registry = wl_display_get_registry(d->display);
    static const wl_registry_listener registryListener = {&State::global, &State::globalRemove};
    wl_registry_add_listener(d->registry, &registryListener, d.get());
    d->wake = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (wl_display_roundtrip(d->display) < 0 || !d->compositor || !d->shm || !d->layerShell || d->wake < 0) {
        d->disconnect();
        return;
    }
    d->alive = true;
    d->thread = std::thread([state = d.get()] { state->run(); });
}

LayerShellPill::~LayerShellPill() {
    if (d->thread.joinable()) {
        d->post({Command::Quit});
        d->thread.join();
    }
    d->disconnect();
}

bool LayerShellPill::available() const { return d->alive; }
void LayerShellPill::start(double time, bool reduced) { if (d->alive) d->post({Command::Start, time, reduced}); }
void LayerShellPill::promote(double time) { if (d->alive) d->post({Command::Promote, time}); }
void LayerShellPill::hide(double time) { if (d->alive) d->post({Command::Hide, time}); }
