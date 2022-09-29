const std = @import("std");
const x11 = @cImport({
    @cInclude("X11/Xatom.h");
    @cInclude("X11/Xlib.h");
    @cInclude("X11/extensions/Xinerama.h");
    @cInclude("Imlib2.h");
});

pub fn main() !void {
    const desktop = load_desktop();
    defer desktop.close();

    std.debug.print("Screen size is {d} {d}.\n", .{ desktop.width, desktop.height });

    const monitors = try desktop.load_monitors(try fetch_dirname_args());

    desktop.configure_imlib_context();

    while (true) {
        for (monitors) |*current_monitor| {
            current_monitor.render_next_wallpaper();
        }

        desktop.render();
        std.time.sleep(75 * std.time.ns_per_ms);
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

    fn render_next_wallpaper(self: *Monitor) void {
        const wallpaper = self.next_wallpaper();
        x11.imlib_context_set_image(wallpaper.image);
        x11.imlib_render_image_on_drawable(self.x_org, self.y_org);
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

fn load_directory(dirname: []const u8, width: c_int, height: c_int) ![]Wallpaper {
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
        const wallpaper = load_wallpaper(path, width, height);
        try loading_wallpapers.append(wallpaper);
    }
    return loading_wallpapers.items;
}

const Wallpaper = struct {
    width: c_int,
    height: c_int,
    image: x11.Imlib_Image,
};

fn load_wallpaper(filename: []const u8, width: c_int, height: c_int) Wallpaper {
    //const fname = [_][*c]const u8 {filename};

    const img = x11.imlib_load_image(filename.ptr);
    x11.imlib_context_set_image(img);
    defer x11.imlib_context_pop();
    const img_width = x11.imlib_image_get_width();
    const img_height = x11.imlib_image_get_height();

    const buffer = x11.imlib_create_image(width, height);
    x11.imlib_context_set_image(buffer);
    x11.imlib_blend_image_onto_image(img, 0, 0, 0, img_width, img_height, 0, 0, width, height);

    x11.imlib_context_set_image(img);
    x11.imlib_free_image();

    return Wallpaper{
        .width = img_width,
        .height = img_height,
        .image = buffer,
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
        _ = x11.XChangeProperty(self.display, root, atom_root, x11.XA_PIXMAP, 32, x11.PropModeReplace, @ptrToInt(&self.pixmap), 1);
        _ = x11.XChangeProperty(self.display, root, atom_eroot, x11.XA_PIXMAP, 32, x11.PropModeReplace, @ptrToInt(&self.pixmap), 1);
    }

    fn load_monitors(self: Desktop, dirnames: [][]const u8) ![]Monitor {
        var monitor_count: c_int = 0;
        const xmonitors = x11.XineramaQueryScreens(self.display, &monitor_count);
        std.debug.print("There are {d} Xmonitors.\n", .{monitor_count});
        var monitors = std.ArrayList(Monitor).init(std.heap.page_allocator);
        var monitor_index: usize = 0;
        while (monitor_index < monitor_count) : (monitor_index += 1) {
            const xmonitor = xmonitors[monitor_index];
            const wallpaper_name = dirnames[monitor_index % dirnames.len];

            var monitor = Monitor{
                .wallpapers = try load_directory(wallpaper_name, xmonitor.width, xmonitor.height),
                .x_org = xmonitor.x_org,
                .y_org = xmonitor.y_org,
                .width = xmonitor.width,
                .height = xmonitor.height,
            };
            try monitors.append(monitor);
        }
        return monitors.items;
    }

    fn configure_imlib_context(self: Desktop) void {
        const screen = @intCast(usize, 0);
        x11.imlib_context_set_display(self.display);
        x11.imlib_context_set_visual(x11.DefaultVisual(self.display, screen));
        x11.imlib_context_set_colormap(x11.DefaultColormap(self.display, screen));

        x11.imlib_context_set_dither(1);
        x11.imlib_context_set_blend(1);
        x11.imlib_context_set_drawable(self.pixmap);
        const root = x11.RootWindow(self.display, screen);
        _ = x11.XSetWindowBackgroundPixmap(self.display, root, self.pixmap);
        _ = x11.XSetCloseDownMode(self.display, x11.RetainTemporary);
    }

    fn render(self: Desktop) void {
        self.set_atoms();
        const screen = @intCast(usize, 0);
        const root = x11.RootWindow(self.display, screen);
        _ = x11.XKillClient(self.display, x11.AllTemporary);
        _ = x11.XClearWindow(self.display, root);
        _ = x11.XFlush(self.display);
        _ = x11.XSync(self.display, 0);
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

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
