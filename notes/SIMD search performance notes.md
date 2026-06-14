# SIMD feature search performance notes

As of right now, feature names are searched in the bin files via a very basic search method:

```zig
for (0..num_features_in_bin) {
    // calc next bin feature name address & get name u8 slice
    if (std.mem.eql(u8, name_to_search, name_in_bin)) return true;
}
```

However, with huge files, I'm worried this will slow down performance. (I think I've already seen canipls performance be not great on JavaScript files of any size.)

I want to employ SIMD in the searching--likely as seen in [this approach](https://aarol.dev/posts/zig-simd-substr)--to speed things up, and measure the performance of the above (old) way vs. the SIMD (new) way.

## The process!

### File to test on
First, I need a massive JS file to test on. I guess it's fine if it's minified. Perhaps `datastar.js`? Or the htmx one if it's larger which I think it is?

| file | minified? | size |
| - | - | - |
| `datastar.js` | yes | 34,092 |
| `htmx.min.js` | yes | 51,240 |
| `htmx.js` | no | 173,977 |

Hmm, so I might try it on the un-minified `htmx.js` file.

### What to test

How should I measure performance? I can simply measure the time it takes to execute the `getDiagnosticsFromCode()` function in `Parser.zig`. That's where the important logic happens.

Whelp I just opened `htmx.js` in Helix and the canipls performance was simply unacceptable. It takes a second or two *between each keystroke* to parse the whole file, so to type:
```typescript
const now = Temporal.Now.instant();
```
Took like 20+ seconds for all the diagnostics to actually show up. Yikes. Before I worry about SIMD, is there any way to debounce this?

Well I'll go ahead with SIMD for now and just isolate that performance improvement. I'll only measure on document open, won't worry about editing for now.

I am going to test both debug and release build performance, before doing SIMD stuff and after, *only surrounding the while cursor next match loop* inside `getDiagnosticsFromCode()`.

### Results before

- debug build
    - 346,614 μs
    - 248,002 μs
    - 245,960 μs
    - 247,190 μs
    - 242,426 μs
    - 245,892 μs
    - 241,750 μs
    - 277,690 μs
    - 244,651 μs
    - 276,866 μs
- release build
    - 12,297 μs
    - 10,605 μs
    - 10,815 μs
    - 10,701 μs
    - 13,272 μs
    - 10,317 μs
    - 11,103 μs
    - 10,480 μs
    - 10,686 μs
    - 10,554 μs
