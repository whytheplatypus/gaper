const std = @import("std");
const x11 = @cImport({
    @cInclude("X11/Xatom.h");
    @cInclude("X11/Xlib.h");
    @cInclude("X11/extensions/Xinerama.h");
    @cInclude("SDL2/SDL.h");
});

pub fn main() !void {
    const desktop = Desktop.init();
    std.debug.print("Desktop loaded.\nScreen size is {d} {d}.\n", .{ desktop.width, desktop.height });
    defer desktop.close();

    std.debug.print("Creating SDL Window.\n", .{});
    const renderer = SDL.init(desktop.window);
    defer renderer.close();

    const gifs = try renderer.load_gifs(try fetch_dirname_args());

    const monitors = try Monitor.get_monitors_from(desktop.display);

    while (true) {
        for (monitors) |current_monitor, index| {
            const gif = &gifs[index % gifs.len];
            renderer.draw(gif.next(), current_monitor.rect);
        }

        renderer.render();

        if (SDL.done()) {
            break;
        }

        std.time.sleep(150 * std.time.ns_per_ms);
    }
}

const Desktop = struct {
    width: c_int,
    height: c_int,
    display: ?*x11.Display,
    window: x11.Window,

    fn close(self: Desktop) void {
        _ = x11.XDestroyWindow(self.display, self.window);
        _ = x11.XCloseDisplay(self.display);
    }

    fn init() Desktop {
        const display = x11.XOpenDisplay(null);
        const screen = @intCast(usize, 0);
        const root = x11.RootWindow(display, screen);
        const width = x11.DisplayWidth(display, screen);
        const height = x11.DisplayHeight(display, screen);

        const x11window = x11.XCreateSimpleWindow(display, root, 0, 0, @intCast(c_uint, width), @intCast(c_uint, height), 1, x11.BlackPixel(display, screen), x11.WhitePixel(display, screen));

        const atom_type = x11.XInternAtom(display, "_NET_WM_WINDOW_TYPE", 0);
        const atom_desktop = x11.XInternAtom(display, "_NET_WM_WINDOW_TYPE_DESKTOP", 0);
        _ = x11.XChangeProperty(display, x11window, atom_type, x11.XA_ATOM, 32, x11.PropModeReplace, @ptrCast([*c]const u8, &atom_desktop), 1);

        _ = x11.XMapWindow(display, x11window);
        _ = x11.XSync(display, 0);

        return Desktop{
            .width = width,
            .height = height,
            .display = display,
            .window = x11window,
        };
    }
};

const Monitor = struct {
    rect: x11.SDL_Rect,

    // move to Monitor
    fn get_monitors_from(display: ?*x11.Display) ![]Monitor {
        var monitor_count: c_int = 0;
        const xmonitors = x11.XineramaQueryScreens(display, &monitor_count);
        std.debug.print("There are {d} Xmonitors.\n", .{monitor_count});
        var monitors = std.ArrayList(Monitor).init(std.heap.page_allocator);
        var monitor_index: usize = 0;
        while (monitor_index < monitor_count) : (monitor_index += 1) {
            const xmonitor = xmonitors[monitor_index];

            var monitor = Monitor{
                .rect = x11.SDL_Rect{
                    .x = xmonitor.x_org,
                    .y = xmonitor.y_org,
                    .w = xmonitor.width,
                    .h = xmonitor.height,
                },
            };
            try monitors.append(monitor);
        }
        return monitors.items;
    }
};

const SDL = struct {
    renderer: ?*x11.SDL_Renderer,
    window: ?*x11.SDL_Window,

    fn draw(self: SDL, image: ?*x11.SDL_Texture, rect: x11.SDL_Rect) void {
        _ = x11.SDL_RenderCopy(self.renderer, image, null, &rect);
    }

    fn render(self: SDL) void {
        x11.SDL_RenderPresent(self.renderer);
    }

    fn load_gifs(self: SDL, dirnames: [][]const u8) ![]GIF {
        var gifs = std.ArrayList(GIF).init(std.heap.page_allocator);
        for (dirnames) |dirname| {
            const files = try get_sorted_frame_files(dirname);
            const frames = try load_frames(files, self.renderer);
            try gifs.append(GIF{
                .images = frames,
            });
        }
        return gifs.items;
    }

    fn close(self: SDL) void {
        x11.SDL_DestroyRenderer(self.renderer);
        x11.SDL_DestroyWindow(self.window);
        x11.SDL_Quit();
    }

    fn init(x11window: x11.Window) SDL {
        _ = x11.SDL_Init(x11.SDL_INIT_VIDEO);
        const window = x11.SDL_CreateWindowFrom(@intToPtr(*const anyopaque, x11window));

        const renderer = x11.SDL_CreateRenderer(window, -1, x11.SDL_RENDERER_ACCELERATED | x11.SDL_RENDERER_PRESENTVSYNC);

        return SDL{
            .renderer = renderer,
            .window = window,
        };
    }

    fn done() bool {
        var event: x11.SDL_Event = undefined;
        _ = x11.SDL_PollEvent(&event);

        return event.type == x11.SDL_QUIT;
    }
};

const GIF = struct {
    index: usize = 0,
    images: []?*x11.SDL_Texture,

    fn next(self: *GIF) ?*x11.SDL_Texture {
        defer self.index = (self.index + 1) % self.images.len;
        return self.images[self.index];
    }
};

fn fetch_dirname_args() error{OutOfMemory}![][]const u8 {
    var args = std.process.args();
    _ = args.skip();
    var dirnames = std.ArrayList([]const u8).init(std.heap.page_allocator);
    while (args.next()) |entry| {
        try dirnames.append(entry);
    }
    return dirnames.items;
}

fn comp_strings(_: void, first: []const u8, second: []const u8) bool {
    if (second.len != first.len) {
        return first.len < second.len;
    }

    var i: usize = 0;
    while (i < first.len) : (i += 1) {
        if (first[i] < second[i]) {
            return true;
        }
        if (first[i] > second[i]) {
            return false;
        }
    }
    return false;
}

fn get_sorted_frame_files(dirname: []const u8) ![][]const u8 {
    std.debug.print("opening {s}.\n", .{dirname});
    var loading_files = std.ArrayList([]const u8).init(std.heap.page_allocator);
    const dir = try std.fs.cwd().openIterableDir(dirname, .{});

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .File) {
            const path = try std.fs.path.join(std.heap.page_allocator, &[_][]const u8{ dirname, entry.name });
            // out of order
            try loading_files.append(path);
        }
    }

    var files = loading_files.items;
    std.sort.sort([]const u8, files, {}, comp_strings);
    return files;
}

fn load_frames(files: [][]const u8, renderer: ?*x11.SDL_Renderer) ![]?*x11.SDL_Texture {
    var frames = std.ArrayList(?*x11.SDL_Texture).init(std.heap.page_allocator);
    for (files) |path| {
        std.debug.print("loading {s}.\n", .{path});
        const frame = load_frame(path, renderer);
        try frames.append(frame);
    }
    return frames.items;
}

fn load_frame(filename: []const u8, renderer: ?*x11.SDL_Renderer) ?*x11.SDL_Texture {
    const surface = x11.SDL_LoadBMP(filename.ptr);
    const texture = x11.SDL_CreateTextureFromSurface(renderer, surface);
    x11.SDL_FreeSurface(surface);
    return texture;
}
