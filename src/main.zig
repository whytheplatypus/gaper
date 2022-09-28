const std = @import("std");
const x11 = @cImport({
    @cInclude("X11/Xatom.h");
    @cInclude("X11/Xlib.h");
    @cInclude("X11/extensions/Xinerama.h");
    @cInclude("Imlib2.h");
});

pub fn main() !void {
    const dirnames = try fetch_dirname_args();

    var mw = std.ArrayList([]Wallpaper).init(std.heap.page_allocator);
    for (dirnames) |filename| {
        try mw.append(try load_directory(filename));
    }

    // shoudl probably be closing dir
    const monitor_wallpapers = mw.items;
    const desktop = load_desktop();
    defer desktop.close();
    const display = desktop.display;

    std.debug.print("Screen size is {d} {d}.\n", .{ desktop.width, desktop.height });

    const buffer = x11.imlib_create_image(desktop.width, desktop.height);
    defer x11.imlib_free_image();
    x11.imlib_context_set_image(buffer);

    const screen = @intCast(usize, 0);
    const root = x11.RootWindow(display, screen);

    // TODO extract monitor retrieval
    var monitor_count: c_int = 0;
    const xmonitors = x11.XineramaQueryScreens(display, &monitor_count);
    std.debug.print("There are {d} Xmonitors.\n", .{monitor_count});
    var monitors = std.ArrayList(Monitor).init(std.heap.page_allocator);
    var monitor_index: usize = 0;
    while (monitor_index < monitor_count) : (monitor_index += 1) {
        const xmonitor = xmonitors[monitor_index];
        const wallpaper_index = monitor_index % monitor_wallpapers.len;
        std.debug.print("Attaching wallpaper {d} to monitor {d}\n", .{ wallpaper_index, monitor_index });
        var monitor = Monitor{
            .wallpapers = monitor_wallpapers[wallpaper_index],
            .x_org = xmonitor.x_org,
            .y_org = xmonitor.y_org,
            .width = xmonitor.width,
            .height = xmonitor.height,
        };
        try monitors.append(monitor);
    }

    x11.imlib_context_set_display(display);
    x11.imlib_context_set_visual(x11.DefaultVisual(display, screen));
    x11.imlib_context_set_colormap(x11.DefaultColormap(display, screen));

    x11.imlib_context_set_dither(1);
    x11.imlib_context_set_blend(1);
    x11.imlib_context_set_drawable(desktop.pixmap);

    while (true) {
        for (monitors.items) |*current_monitor| {
            const wallpaper = current_monitor.next_wallpaper();
            // TODO extract monitor debug info gathering
            //std.debug.print("Monitor {d} is {d} {d} {d} {d}.\n", .{ i, current_monitor.x_org, current_monitor.y_org, current_monitor.width, current_monitor.height });

            x11.imlib_blend_image_onto_image(wallpaper.image, 0, 0, 0, wallpaper.width, wallpaper.height, current_monitor.x_org, current_monitor.y_org, current_monitor.width, current_monitor.height);
        }

        // use monitor specs here
        x11.imlib_render_image_on_drawable(0, 0);
        desktop.set_atoms();
        _ = x11.XKillClient(display, x11.AllTemporary);
        _ = x11.XSetCloseDownMode(display, x11.RetainTemporary);
        _ = x11.XSetWindowBackgroundPixmap(display, root, desktop.pixmap);
        _ = x11.XClearWindow(display, root);
        _ = x11.XFlush(display);
        _ = x11.XSync(display, 0);
        std.time.sleep(75 * std.time.ns_per_ms);
    }
    defer _ = x11.XFreePixmap(display, desktop.pixmap);
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

fn load_directory(dirname: []const u8) ![]Wallpaper {
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
        const wallpaper = load_wallpaper(path);
        try loading_wallpapers.append(wallpaper);
    }
    return loading_wallpapers.items;
}

const Wallpaper = struct {
    width: c_int,
    height: c_int,
    image: x11.Imlib_Image,
};

fn load_wallpaper(filename: []const u8) Wallpaper {
    //const fname = [_][*c]const u8 {filename};

    const img = x11.imlib_load_image(filename.ptr);
    x11.imlib_context_set_image(img);
    defer x11.imlib_context_pop();
    const img_width = x11.imlib_image_get_width();
    const img_height = x11.imlib_image_get_height();
    return Wallpaper{
        .width = img_width,
        .height = img_height,
        .image = img,
    };
}

const Desktop = struct {
    width: c_int,
    height: c_int,
    display: ?*x11.Display,
    pixmap: x11.Pixmap,

    fn close(self: Desktop) void {
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
