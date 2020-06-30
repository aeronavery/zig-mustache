# zig-mustache
A [mustache](http://mustache.github.io/mustache.5.html) template renderer written in Zig. The Mustache object first compiles the template and caches the result. The same Mustache object can then be used to render the template on demand given any value.

# Getting Started

Here the template is rendered into an ArrayList:

```zig
var result = std.ArrayList(u8).init(std.testing.allocator);
defer result.deinit();

var out_stream = result.outStream();

var mustache = Mustache.init(std.testing.allocator);
defer mustache.deinit();
try mustache.render(@TypeOf(out_stream), out_stream, 
  "tests/test1.must", 
  .{ 
    .foo = 69, 
    .bar = .{ .thing = 10 }, 
    .not_bar = false 
  });
```
