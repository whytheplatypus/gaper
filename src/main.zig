const std = @import("std");
const x11 = @cImport({
    @cInclude("X11/Xatom.h");
    @cInclude("X11/Xlib.h");
    @cInclude("X11/extensions/Xinerama.h");
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_syswm.h");
});

pub fn main() !void {
    const desktop = load_desktop();
    desktop.configure();
    std.debug.print("Desktop loaded.\n", .{});
    defer desktop.close();
    std.debug.print("Creating SDL Window.\n", .{});
    const screen = @intCast(usize, 0);
    const root = x11.RootWindow(desktop.display, screen);
    //const window = x11.SDL_CreateWindowFrom(@intToPtr(*const anyopaque, root));
    const x11window = x11.XCreateSimpleWindow(desktop.display, root, 0, 0, @intCast(c_uint, desktop.width), @intCast(c_uint, desktop.height), 1, x11.BlackPixel(desktop.display, screen), x11.WhitePixel(desktop.display, screen));
    defer _ = x11.XDestroyWindow(desktop.display, x11window);
    const atom_type = x11.XInternAtom(desktop.display, "_NET_WM_WINDOW_TYPE", 0);
    const atom_desktop = x11.XInternAtom(desktop.display, "_NET_WM_WINDOW_TYPE_DESKTOP", 0);
    _ = x11.XChangeProperty(desktop.display, x11window, atom_type, x11.XA_ATOM, 32, x11.PropModeReplace, @ptrCast([*c]const u8, &atom_desktop), 1);
    _ = x11.XMapWindow(desktop.display, x11window);
    _ = x11.XSync(desktop.display, 0);

    _ = x11.SDL_Init(x11.SDL_INIT_VIDEO);
    std.debug.print("SDL Initialized.\n", .{});
    defer x11.SDL_Quit();
    const window = x11.SDL_CreateWindowFrom(@intToPtr(*const anyopaque, x11window));

    //const window = x11.SDL_CreateWindow("SDL pixels", 0, 0, desktop.width, desktop.height, x11.SDL_WINDOW_SHOWN);
    std.debug.print("SDL Window created.\n", .{});
    defer x11.SDL_DestroyWindow(window);

    const renderer = x11.SDL_CreateRenderer(window, -1, x11.SDL_RENDERER_ACCELERATED | x11.SDL_RENDERER_PRESENTVSYNC);

    std.debug.print("SDL Renderer created.\n", .{});
    defer x11.SDL_DestroyRenderer(renderer);

    std.debug.print("Screen size is {d} {d}.\n", .{ desktop.width, desktop.height });

    const monitors = try desktop.load_monitors(try fetch_dirname_args(), renderer);

    while (true) {
        for (monitors) |*current_monitor| {
            current_monitor.render_next_wallpaper(renderer);
        }

        desktop.render(renderer);

        var event: x11.SDL_Event = undefined;
        _ = x11.SDL_PollEvent(&event);

        if (event.type == x11.SDL_QUIT) {
            break;
        }

        std.time.sleep(150 * std.time.ns_per_ms);
    }
}

const Monitor = struct {
    wallpapers: []Wallpaper,
    index: usize = 0,
    x_org: c_int,
    y_org: c_int,
    width: c_int,
    height: c_int,

    fn next_wallpaper(self: *Monitor) Wallpaper {
        self.index = (self.index + 1) % self.wallpapers.len;
        return self.wallpapers[self.index];
    }

    fn render_next_wallpaper(self: *Monitor, renderer: ?*x11.SDL_Renderer) void {
        const wallpaper = self.next_wallpaper();
        const rect = &x11.SDL_Rect{
            .x = self.x_org,
            .y = self.y_org,
            .w = self.width,
            .h = self.height,
        };
        _ = x11.SDL_RenderCopy(renderer, wallpaper.image, null, rect);
    }
};

// return true if first is less than the second
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

fn fetch_dirname_args() error{OutOfMemory}![][]const u8 {
    var args = std.process.args();
    _ = args.skip();
    var dirnames = std.ArrayList([]const u8).init(std.heap.page_allocator);
    while (args.next()) |entry| {
        try dirnames.append(entry);
    }
    return dirnames.items;
}

fn load_directory(dirname: []const u8, renderer: ?*x11.SDL_Renderer) ![]Wallpaper {
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

    var loading_wallpapers = std.ArrayList(Wallpaper).init(std.heap.page_allocator);
    var files = loading_files.items;
    std.sort.sort([]const u8, files, {}, comp_strings);
    for (files) |path| {
        std.debug.print("loading {s}.\n", .{path});
        const wallpaper = load_wallpaper(path, renderer);
        try loading_wallpapers.append(wallpaper);
    }
    return loading_wallpapers.items;
}

const Wallpaper = struct {
    image: ?*x11.SDL_Texture,
};

fn load_wallpaper(filename: []const u8, renderer: ?*x11.SDL_Renderer) Wallpaper {
    const surface = x11.SDL_LoadBMP(filename.ptr);
    const texture = x11.SDL_CreateTextureFromSurface(renderer, surface);
    x11.SDL_FreeSurface(surface);

    return Wallpaper{
        .image = texture,
    };
}

const Desktop = struct {
    width: c_int,
    height: c_int,
    display: ?*x11.Display,
    pixmap: x11.Pixmap,

    fn close(self: Desktop) void {
        _ = x11.XFreePixmap(self.display, self.pixmap);
        _ = x11.XCloseDisplay(self.display);
    }

    fn set_atoms(self: Desktop) void {
        const atom_root = x11.XInternAtom(self.display, "_XROOTPMAP_ID", 0);
        const atom_eroot = x11.XInternAtom(self.display, "ESETROOT_PMAP_ID", 0);
        const screen = @intCast(usize, 0);
        const root = x11.RootWindow(self.display, screen);
        // @ptrToInt tells C the address of the pixmap
        _ = x11.XChangeProperty(self.display, root, atom_root, x11.XA_PIXMAP, 32, x11.PropModeReplace, @ptrToInt(&root), 1);
        _ = x11.XChangeProperty(self.display, root, atom_eroot, x11.XA_PIXMAP, 32, x11.PropModeReplace, @ptrToInt(&root), 1);
    }

    fn load_monitors(self: Desktop, dirnames: [][]const u8, renderer: ?*x11.SDL_Renderer) ![]Monitor {
        var monitor_count: c_int = 0;
        const xmonitors = x11.XineramaQueryScreens(self.display, &monitor_count);
        std.debug.print("There are {d} Xmonitors.\n", .{monitor_count});
        var monitors = std.ArrayList(Monitor).init(std.heap.page_allocator);
        var monitor_index: usize = 0;
        while (monitor_index < monitor_count) : (monitor_index += 1) {
            const xmonitor = xmonitors[monitor_index];
            const wallpaper_name = dirnames[monitor_index % dirnames.len];

            var monitor = Monitor{
                .wallpapers = try load_directory(wallpaper_name, renderer),
                .x_org = xmonitor.x_org,
                .y_org = xmonitor.y_org,
                .width = xmonitor.width,
                .height = xmonitor.height,
            };
            try monitors.append(monitor);
        }
        return monitors.items;
    }

    fn configure(self: Desktop) void {
        const screen = @intCast(usize, 0);
        const root = x11.RootWindow(self.display, screen);
        _ = x11.XSetWindowBackgroundPixmap(self.display, root, self.pixmap);
        _ = x11.XSetCloseDownMode(self.display, x11.RetainTemporary);
    }

    fn render(self: Desktop, renderer: ?*x11.SDL_Renderer) void {
        x11.SDL_RenderPresent(renderer);

        self.set_atoms();
        //const screen = @intCast(usize, 0);
        //const root = x11.RootWindow(self.display, screen);
        //_ = x11.XKillClient(self.display, x11.AllTemporary);
        //_ = x11.XClearWindow(self.display, root);
        //_ = x11.XFlush(self.display);
        //_ = x11.XSync(self.display, 0);
    }
};

fn load_desktop() Desktop {
    const display = x11.XOpenDisplay(null);
    const screen = @intCast(usize, 0);
    const root = x11.RootWindow(display, screen);
    const width = x11.DisplayWidth(display, screen);
    const height = x11.DisplayHeight(display, screen);
    return Desktop{
        .width = width,
        .height = height,
        .display = display,
        .pixmap = x11.XCreatePixmap(display, root, @intCast(c_uint, width), @intCast(c_uint, height), @intCast(c_uint, x11.DefaultDepth(display, screen))),
    };
}
