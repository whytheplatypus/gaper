# Zaper

Zaper is an animated desktop background setter for X11

This was created as an excuse to experiment with zig and generally practice.

Inspired by [paperview](https://github.com/glouw/paperview) with a goal of getting it to work with compositors like picom.

## Build

zig build -Drelease-safe

## Usage

### Creating a scene

```
mkdir ascene
cd ascene
convert -coalesce path/to/animated.gif out.bmp
```

### Setting a scene

```
zap ascene..
```

To set a scene per monitor supply a folder for each:

```
# for example I have two monitors:
zap left right
```

## Known Issues

In order to work with picom this creates a new x11 desktop to paint the animation on, I'm betting this could cause some people problems.
