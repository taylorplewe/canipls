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

| file          | minified? | size    |
| ------------- | --------- | ------- |
| `datastar.js` | yes       | 34,092  |
| `htmx.min.js` | yes       | 51,240  |
| `htmx.js`     | no        | 173,977 |

Hmm, so I might try it on the un-minified `htmx.js` file.

### What to test

How should I measure performance? I can simply measure the time it takes to execute the `getDiagnosticsFromCode()` function in `Parser.zig`. That's where the important logic happens.

Whelp I just opened `htmx.js` in Helix and the canipls performance was simply unacceptable. It takes a second or two _between each keystroke_ to parse the whole file, so to type:

```typescript
const now = Temporal.Now.instant();
```

Took like 20+ seconds for all the diagnostics to actually show up. Yikes. Before I worry about SIMD, is there any way to debounce this?

Well I'll go ahead with SIMD for now and just isolate that performance improvement. I'll only measure on document open, won't worry about editing for now.

I am going to test both debug and release build performance, before doing SIMD stuff and after, _only surrounding the while cursor next match loop_ inside `getDiagnosticsFromCode()`.

### The SIMD code

First, check the current CPU's natural SIMD vector width:

```zig
const maybe_block_size = std.simd.suggestVectorLength(u8);
const SimdString = if (maybe_block_size) |block_size|
    @Vector(block_size, u8)
else
    @Vector(8, u8); // This isn't really necessary but i need some kind of fallback
```

Then, in the actual search loop:

```zig
if (maybe_block_size) |block_size| {
    var iteration: usize = 0;
    // BIN_FILE_STRING_WIDTH = 32
    // the current machine's SIMD vector width might not be that wide; if so, you'll have to do 2 or more iterations
    while (iteration * block_size < BIN_FILE_STRING_WIDTH) : (iteration += 1) {
        const index = iteration * block_size;
        const name_searching: SimdString = name_padded[index..][0..block_size].*;
        const name_bin: SimdString = self.data[(next_identifier_offset + index)..][0..block_size].*;
        const eq = ~(name_searching == name_bin);
        const eq_bit_set: std.bit_set.IntegerBitSet(block_size) = .{ .mask = @bitCast(eq) };
        if (eq_bit_set.findFirstSet() != null) continue :name_loop;
    }
    return i;
} else {
    // fall back to regular scalar search if SIMD not supported on current machine
    const name_in_bin = self.data[next_identifier_offset..][0..BIN_FILE_STRING_WIDTH];
    if (name_padded.len != name_in_bin.len) unreachable; // optimize away unneeded length checks; we know they are the same
    if (std.mem.eql(u8, name_padded, name_in_bin)) return i;
}
```

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

### Results after

- debug build
    - 230,271 μs
    - 223,812 μs
    - 306,302 μs
    - 235,959 μs
    - 222,332 μs
    - 223,519 μs
    - 252,362 μs
    - 229,374 μs
    - 224,188 μs
    - 224,618 μs
- release build
    - 9,400 μs
    - 10,004 μs
    - 9,727 μs
    - 10,962 μs
    - 12,255 μs
    - 9,611 μs
    - 9,824 μs
    - 9,708 μs
    - 9,948 μs
    - 9,560 μs

Whelp it is an improvement but not a huge improvement. I bet that on systems that only have 16-byte SIMD vector width, and have to do 2 iterations, the speed wouldn't even be better; might actually be worse. I can test this on my raspberry pi which I know has a vector width of 16.

### Improvement

I decided to only allow >= 32 SIMD vector lengths into the SIMD search branch. This removes the whole iteration counter thing.

I also realized I was calculating the equality in a dumb way, just copying and pasting code from that article and changing it a little. All I have to do is a simple AND to see if there's any 1s in the equality vector.

New code:

```zig
const maybe_block_size = std.simd.suggestVectorLength(u8);
const is_simd_vector_size_big_enough = if (maybe_block_size) |block_size| block_size >= 32 else false;
const SimdString = @Vector(maybe_block_size orelse 8, u8);
```

and then in the loop:

```zig
const block_size = maybe_block_size.?;
const name_searching: SimdString = name_padded[0..block_size].*;
const name_bin: SimdString = self.data[next_identifier_offset..][0..block_size].*;
const eq = @as(u32, @bitCast(~(name_searching == name_bin)));
if (eq & 0xffffffff != 0) continue :name_loop;
return i;
```

### Results after v2

- debug build
    - 189,562 μs
    - 189,842 μs
    - 206,800 μs
    - 189,813 μs
    - 234,188 μs
    - 191,012 μs
    - 200,164 μs
    - 187,657 μs
    - 189,284 μs
    - 187,750 μs
- release build
    - 10,036 μs
    - 9,651 μs
    - 10,242 μs
    - 9,781 μs
    - 10,438 μs
    - 10,118 μs
    - 10,229 μs
    - 10,161 μs
    - 10,088 μs
    - 9,965 μs

Yikes. Definitely a small improvement for debug builds, but not at all for release build? I wonder why that is, kinda disappointing.

Gonna do some godbolt and see what the output machine code looks like.

### Godbolt results

Godbolt full link: https://godbolt.org/#g:!((g:!((g:!((h:codeEditor,i:(filename:'1',fontScale:16,fontUsePx:'0',j:1,lang:zig,selection:(endColumn:2,endLineNumber:15,positionColumn:2,positionLineNumber:15,selectionStartColumn:2,selectionStartLineNumber:15,startColumn:2,startLineNumber:15),source:'const+SimdString+%3D+@Vector(32,+u8)%3B%0A%0Aexport+fn+findInStr(%0A++++haystack_ptr:+%5B*%5Du8,%0A++++needle_ptr:+%5B*%5Du8,%0A)+bool+%7B%0A++++const+haystack:+%5B%5Dconst+u8+%3D+haystack_ptr%5B0..32%5D%3B%0A++++const+needle:+%5B%5Dconst+u8+%3D+needle_ptr%5B0..32%5D%3B%0A%0A++++const+haystack_vec:+SimdString+%3D+haystack%5B0..32%5D.*%3B%0A++++const+needle_vec:+SimdString+%3D+needle%5B0..32%5D.*%3B%0A++++const+eq+%3D+@as(u32,+@bitCast(~(haystack_vec+%3D%3D+needle_vec)))%3B%0A++++if+(eq+%26+0xffffffff+!!%3D+0)+return+false%3B%0A++++return+true%3B%0A%7D'),l:'5',n:'0',o:'Zig+source+%231',t:'0')),k:49.725315895112686,l:'4',n:'0',o:'',s:0,t:'0'),(g:!((h:compiler,i:(compiler:z0160,filters:(b:'0',binary:'1',binaryObject:'1',commentOnly:'0',debugCalls:'1',demangle:'0',directives:'0',execute:'0',intel:'0',libraryCode:'0',trim:'1',verboseDemangling:'0'),flagsViewOpen:'1',fontScale:14,fontUsePx:'0',j:1,lang:zig,libs:!(),options:'-O+ReleaseFast',overrides:!(),selection:(endColumn:1,endLineNumber:1,positionColumn:1,positionLineNumber:1,selectionStartColumn:1,selectionStartLineNumber:1,startColumn:1,startLineNumber:1),source:1),l:'5',n:'0',o:'+zig+0.16.0+(Editor+%231)',t:'0')),k:50.27468410488733,l:'4',m:100,n:'0',o:'',s:0,t:'0')),l:'2',n:'0',o:'',t:'0')),version:4

Input code:

```zig
const SimdString = @Vector(32, u8);
export fn findInStr(
    haystack_ptr: [*]u8,
    needle_ptr: [*]u8,
) bool {
    const haystack: []const u8 = haystack_ptr[0..32];
    const needle: []const u8 = needle_ptr[0..32];

    const haystack_vec: SimdString = haystack[0..32].*;
    const needle_vec: SimdString = needle[0..32].*;
    const eq = @as(u32, @bitCast(~(haystack_vec == needle_vec)));
    if (eq & 0xffffffff != 0) return false;
    return true;
}
```

Output machine code:

```assembly
example.findInStr:
    push    rbp
    mov     rbp, rsp
    vmovdqu ymm0, ymmword ptr [rdi]
    vpxor   ymm0, ymm0, ymmword ptr [rsi]
    vptest  ymm0, ymm0
    sete    al
    pop     rbp
    vzeroupper
    ret
```

Dang. Looks pretty good. I was gonna try handwriting some SIMD assembly, dynamically linking to the zig program, calling into the foreign function using a calling convention, all that, but I mean...no point if this is what the compiler outputs. I was probably just gonna hand-write that.

vs. the "scalar" search (you'll see why the quotes are there:) https://godbolt.org/#g:!((g:!((g:!((h:codeEditor,i:(filename:'1',fontScale:16,fontUsePx:'0',j:1,lang:zig,selection:(endColumn:2,endLineNumber:11,positionColumn:1,positionLineNumber:1,selectionStartColumn:2,selectionStartLineNumber:11,startColumn:1,startLineNumber:1),source:'const+std+%3D+@import(%22std%22)%3B%0Aexport+fn+findInStr(%0A++++haystack_ptr:+%5B*%5Du8,%0A++++needle_ptr:+%5B*%5Du8,%0A)+bool+%7B%0A++++const+haystack:+%5B%5Dconst+u8+%3D+haystack_ptr%5B0..32%5D%3B%0A++++const+needle:+%5B%5Dconst+u8+%3D+needle_ptr%5B0..32%5D%3B%0A%0A++++if+(haystack.len+!!%3D+needle.len)+unreachable%3B+//+optimize+away+unneeded+length+checks%3B+we+know+they+are+the+same%0A++++return+std.mem.eql(u8,+haystack,+needle)%3B%0A%7D'),l:'5',n:'0',o:'Zig+source+%231',t:'0')),k:49.81687726340846,l:'4',n:'0',o:'',s:0,t:'0'),(g:!((h:compiler,i:(compiler:z0160,filters:(b:'0',binary:'1',binaryObject:'1',commentOnly:'0',debugCalls:'1',demangle:'0',directives:'0',execute:'0',intel:'0',libraryCode:'0',trim:'1',verboseDemangling:'0'),flagsViewOpen:'1',fontScale:14,fontUsePx:'0',j:1,lang:zig,libs:!(),options:'-O+ReleaseFast',overrides:!(),selection:(endColumn:1,endLineNumber:1,positionColumn:1,positionLineNumber:1,selectionStartColumn:1,selectionStartLineNumber:1,startColumn:1,startLineNumber:1),source:1),l:'5',n:'0',o:'+zig+0.16.0+(Editor+%231)',t:'0')),k:50.18312273659156,l:'4',m:100,n:'0',o:'',s:0,t:'0')),l:'2',n:'0',o:'',t:'0')),version:4

Input code:

```zig
const std = @import("std");
export fn findInStr(
    haystack_ptr: [*]u8,
    needle_ptr: [*]u8,
) bool {
    const haystack: []const u8 = haystack_ptr[0..32];
    const needle: []const u8 = needle_ptr[0..32];

    if (haystack.len != needle.len) unreachable; // optimize away unneeded length checks; we know they are the same
    return std.mem.eql(u8, haystack, needle);
}
```

Output machine code:

```assembly
example.findInStr:
    push    rbp
    mov     rbp, rsp
    cmp     rdi, rsi
    je      .LBB0_1
    vmovdqu xmm0, xmmword ptr [rdi]
    vmovdqu xmm1, xmmword ptr [rdi + 16]
    vpxor   xmm0, xmm0, xmmword ptr [rsi]
    vpxor   xmm1, xmm1, xmmword ptr [rsi + 16]
    vpor    xmm0, xmm0, xmm1
    vptest  xmm0, xmm0
    sete    al
    pop     rbp
    ret
.LBB0_1:
    mov     al, 1
    pop     rbp
    ret
```

Lmao. Moral of the story: LLVM is smart. I guess you don't even need to be that smart given the setup I gave it. I basically gave it a layup.

So basically, my simd version is a little faster because it uses 32-byte vectors instead of 2 16-byte vectors. Makes sense why it's not a huge improvement.

---

EDIT (7/28/26): I realized the machine code output is doing _unaligned SIMD moves_. If I make sure every 32-byte-wide feature name is aligned to 32 bytes, I can use aligned SIMD instructions (`vmovdqa` instead of `vmovdqu`.) I'm very curious just how much of a perf increase that would be.

Problem is, there's actually real people (not that much, but still) using canipls now, mostly thru VS Code, so just how I can safely modify the bin files will be tricky. I can't just update the bin files to be aligned, it will break everyone's canipls. I'm not sure if it will crash and make their editor freak out or not. I'd have to quickly (as atomically as possible) update canipls itself to the new parsing code which has the align check, so everyone gets the updated canipls version quickly that parses the new bin files correctly.

I verified this in godbolt. by adding the following line before the memory read:

```zig
// use aligned SIMD instruction (`vmovdqa`) instead of unaligned instruction (`vmovdqu`)
if (@intFromPtr(haystack.ptr) & 31 != 0) unreachable; // or 0b1_1111, 0x1f or 0b11111 instead of 31
```

it does indeed emit the aligned instruction.

Full godbolt link: https://godbolt.org/#g:!((g:!((g:!((h:codeEditor,i:(filename:'1',fontScale:16,fontUsePx:'0',j:1,lang:zig,selection:(endColumn:1,endLineNumber:11,positionColumn:1,positionLineNumber:11,selectionStartColumn:1,selectionStartLineNumber:10,startColumn:1,startLineNumber:10),source:'const+SimdString+%3D+@Vector(32,+u8)%3B%0A%0Aexport+fn+findInStr(%0A++++haystack_ptr:+%5B*%5Du8,%0A++++needle_ptr:+%5B*%5Du8,%0A)+bool+%7B%0A++++const+haystack:+%5B%5Dconst+u8+%3D+haystack_ptr%5B0..32%5D%3B%0A++++const+needle:+%5B%5Dconst+u8+%3D+needle_ptr%5B0..32%5D%3B%0A%0A++++if+(@intFromPtr(haystack.ptr)+%26+31+!!%3D+0)+unreachable%3B%0A++++const+haystack_vec:+SimdString+%3D+haystack%5B0..32%5D.*%3B%0A++++const+needle_vec:+SimdString+%3D+needle%5B0..32%5D.*%3B%0A++++const+eq+%3D+@as(u32,+@bitCast(~(haystack_vec+%3D%3D+needle_vec)))%3B%0A++++if+(eq+%26+0xffffffff+!!%3D+0)+return+false%3B%0A++++return+true%3B%0A%7D'),l:'5',n:'0',o:'Zig+source+%231',t:'0')),k:49.81687726340846,l:'4',n:'0',o:'',s:0,t:'0'),(g:!((h:compiler,i:(compiler:z0160,filters:(b:'0',binary:'1',binaryObject:'1',commentOnly:'0',debugCalls:'1',demangle:'0',directives:'0',execute:'0',intel:'0',libraryCode:'0',trim:'1',verboseDemangling:'0'),flagsViewOpen:'1',fontScale:14,fontUsePx:'0',j:1,lang:zig,libs:!(),options:'-O+ReleaseFast',overrides:!(),selection:(endColumn:1,endLineNumber:1,positionColumn:1,positionLineNumber:1,selectionStartColumn:1,selectionStartLineNumber:1,startColumn:1,startLineNumber:1),source:1),l:'5',n:'0',o:'+zig+0.16.0+(Editor+%231)',t:'0')),k:50.18312273659156,l:'4',m:100,n:'0',o:'',s:0,t:'0')),l:'2',n:'0',o:'',t:'0')),version:4

Input code:

```zig
const SimdString = @Vector(32, u8);

export fn findInStr(
    haystack_ptr: [*]u8,
    needle_ptr: [*]u8,
) bool {
    const haystack: []const u8 = haystack_ptr[0..32];
    const needle: []const u8 = needle_ptr[0..32];

    if (@intFromPtr(haystack.ptr) & 31 != 0) unreachable;
    const haystack_vec: SimdString = haystack[0..32].*;
    const needle_vec: SimdString = needle[0..32].*;
    const eq = @as(u32, @bitCast(~(haystack_vec == needle_vec)));
    if (eq & 0xffffffff != 0) return false;
    return true;
}
```

Output:

```assembly
example.findInStr:
    push    rbp
    mov     rbp, rsp
    vmovdqa ymm0, ymmword ptr [rdi]
    vpxor   ymm0, ymm0, ymmword ptr [rsi]
    vptest  ymm0, ymm0
    sete    al
    pop     rbp
    vzeroupper
    ret
```
