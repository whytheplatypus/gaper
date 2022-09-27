const std = @import("std");
const x11 = @cImport({
    @cInclude("X11/Xatom.h");
    @cInclude("X11/Xlib.h");
    @cInclude("X11/extensions/Xinerama.h");
    @cInclude("Imlib2.h");
});

pub fn main() !void {
    const filename = fetch_filename_arg();
    const wallpaper = load_wallpaper(filename);


    const desktop = load_desktop();
    defer desktop.close();
    const display = desktop.display;

    std.debug.print("Screen size is {d} {d}.\n", .{ desktop.width, desktop.height });

    const buffer = x11.imlib_create_image(desktop.width, desktop.height);
    x11.imlib_context_set_image(buffer);

    const screen = @intCast(usize, 0);
    const root = x11.RootWindow(display, screen);

    // TODO extract monitor retrieval
    var monitor_count: c_int = 0;
    const monitors = x11.XineramaQueryScreens(display, &monitor_count);
    std.debug.print("There are {d} monitors.\n", .{monitor_count});
    // TODO extract monitor debug info gathering
    var monitor_index: usize = 0;
    while (monitor_index < monitor_count) : (monitor_index += 1) {
        const current_monitor = monitors[monitor_index];
        std.debug.print("Monitor {d} is {d} {d} {d} {d}.\n", .{ monitor_index, current_monitor.x_org, current_monitor.y_org, current_monitor.width, current_monitor.height });

        x11.imlib_blend_image_onto_image(wallpaper.image, 0, 0, 0, wallpaper.width, wallpaper.height, current_monitor.x_org, current_monitor.y_org, current_monitor.width, current_monitor.height);
    }

    x11.imlib_context_set_display(display);
    x11.imlib_context_set_visual(x11.DefaultVisual(display, screen));
    x11.imlib_context_set_colormap(x11.DefaultColormap(display, screen));

    x11.imlib_context_set_dither(1);
    x11.imlib_context_set_blend(1);
    x11.imlib_context_set_drawable(desktop.pixmap);

    // use monitor specs here
    x11.imlib_render_image_on_drawable(0, 0);
    desktop.set_atoms();
    _ = x11.XKillClient(display, x11.AllTemporary);
    _ = x11.XSetCloseDownMode(display, x11.RetainTemporary);
    _ = x11.XSetWindowBackgroundPixmap(display, root, desktop.pixmap);
    _ = x11.XClearWindow(display, root);
    _ = x11.XFlush(display);
    _ = x11.XSync(display, 0);
    defer _ = x11.XFreePixmap(display, desktop.pixmap);
    defer x11.imlib_free_image();
}


fn fetch_filename_arg() [*:0]const u8 {
    var args = std.process.args();
    _ = args.skip();
    const filename: [*:0]const u8 = args.next().?;
    return filename;
}

const Wallpaper = struct {
    width: c_int,
    height: c_int,
    image: x11.Imlib_Image,
};

fn load_wallpaper(filename: [*:0]const u8) Wallpaper {
    //const fname = [_][*c]const u8 {filename};

    const img = x11.imlib_load_image(filename);
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
        _ = x11.XChangeProperty(self.display, root, atom_root, x11.XA_PIXMAP, 32, x11.PropModeReplace, @ptrCast(*const u8, &self.pixmap), 1);
        _ = x11.XChangeProperty(self.display, root, atom_eroot, x11.XA_PIXMAP, 32, x11.PropModeReplace, @ptrCast(*const u8, &self.pixmap), 1);
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
