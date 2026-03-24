# Simple Wayland Client

There are TWO Wayland client programs in this repo. The single-file version is
a direct implementation of my related
[blog post](https://ptrtoliam.dev/blog/wlclient-nolibwayland), and lives in
`src/simple-client.zig`. This version can be run with either:

```shell
$ zig build simple-client
# OR:
$ zig run src/simple-client.zig
```

The other implementation utilizes a stripped-down version of
my personal Zig base layer and my own wayland code generation tool, and presents
a more object-oriented interface which is more in-line with what one might
expect, given the object-oriented design of the Wayland protocol. This second
implementation runs from `src/client.zig`. This version can be run with:

```shell
$ zig build client
```
