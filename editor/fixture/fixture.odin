package bsp_decompile_fixture

import "core:encoding/endian"

// A BSP 30 written in code for the tests: a cube [0,64] whose tree is six
// nodes, one per plane; the front of each is an empty leaf and the back of
// the last the solid one. One face, on +z, says the texture CRATE, kept in a
// WAD (only its name) or, with embedded, inside the BSP with its pixels and
// its palette, as GoldSrc keeps the textures a map brings.

LUMPS :: 15
EMBEDDED_COLOR :: [3]u8{200,100,50} // the color of every texel of the embedded CRATE

@(private)
Bytes :: struct {b:[dynamic]u8}

@(private) put_i32 :: proc(w:^Bytes,v:int) {x:[4]u8;endian.put_i32(x[:],.Little,i32(v));append(&w.b,..x[:])}
@(private) put_u16 :: proc(w:^Bytes,v:int) {x:[2]u8;endian.put_u16(x[:],.Little,u16(v));append(&w.b,..x[:])}
@(private) put_i16 :: proc(w:^Bytes,v:int) {x:[2]u8;endian.put_i16(x[:],.Little,i16(v));append(&w.b,..x[:])}
@(private) put_f32 :: proc(w:^Bytes,v:f64) {x:[4]u8;endian.put_f32(x[:],.Little,f32(v));append(&w.b,..x[:])}

@(private)
put_name :: proc(w:^Bytes,name:string,size:int) {
    x:=make([]u8,size,context.temp_allocator)
    copy(x,name)
    append(&w.b,..x)
}

cube_bsp :: proc(embedded:=false,allocator:=context.allocator) -> []u8 {
    context.allocator=allocator
    lumps:[LUMPS]Bytes
    entities:="{\n\"classname\" \"worldspawn\"\n\"wad\" \"\"\n}\n\x00"
    append(&lumps[0].b,..transmute([]u8)entities)
    planes:=[6][4]f64{{1,0,0,64},{-1,0,0,0},{0,1,0,64},{0,-1,0,0},{0,0,1,64},{0,0,-1,0}}
    for p in planes {
        put_f32(&lumps[1],p.x);put_f32(&lumps[1],p.y);put_f32(&lumps[1],p.z)
        put_f32(&lumps[1],p.w);put_i32(&lumps[1],0)
    }
    // textures: one miptex, in a WAD (offsets 0) or here with its four levels and palette
    put_i32(&lumps[2],1);put_i32(&lumps[2],8)
    put_name(&lumps[2],"CRATE",16);put_i32(&lumps[2],64);put_i32(&lumps[2],64)
    if embedded {
        at:=40
        for size in ([4]int{64,32,16,8}) {put_i32(&lumps[2],at);at+=size*size}
        for size in ([4]int{64,32,16,8}) {for _ in 0..<size*size {append(&lumps[2].b,1)}}
        put_u16(&lumps[2],256)
        for i in 0..<256 {
            color:=EMBEDDED_COLOR if i==1 else [3]u8{}
            append(&lumps[2].b,color.r,color.g,color.b)
        }
        append(&lumps[2].b,0,0)
    } else {
        for _ in 0..<4 {put_i32(&lumps[2],0)}
    }
    // vertices of the +z face
    for v in ([4][3]f64{{0,0,64},{64,0,64},{64,64,64},{0,64,64}}) {
        put_f32(&lumps[3],v.x);put_f32(&lumps[3],v.y);put_f32(&lumps[3],v.z)
    }
    // nodes: node i on plane i; front: leaf 1 (empty, child -2); back: node i+1, the last leaf 2 (solid, -3)
    for i in 0..<6 {
        put_i32(&lumps[5],i)
        put_i16(&lumps[5],-2)
        put_i16(&lumps[5],i+1 if i<5 else -3)
        for _ in 0..<3 {put_i16(&lumps[5],-1)}
        for _ in 0..<3 {put_i16(&lumps[5],65)}
        put_u16(&lumps[5],0);put_u16(&lumps[5],1 if i==4 else 0)
    }
    // texinfo: s along x, t along -y, one texel per unit
    for v in ([8]f64{1,0,0,0, 0,-1,0,0}) {put_f32(&lumps[6],v)}
    put_i32(&lumps[6],0);put_i32(&lumps[6],0)
    // the face on plane 4 (+z), looking up
    put_u16(&lumps[7],4);put_u16(&lumps[7],0);put_i32(&lumps[7],0);put_u16(&lumps[7],4);put_u16(&lumps[7],0)
    put_i32(&lumps[7],0);put_i32(&lumps[7],-1)
    // leaves: 0 solid (by custom), 1 empty, 2 solid
    for contents in ([3]int{-2,-1,-2}) {
        put_i32(&lumps[10],contents)
        for _ in 0..<24 {append(&lumps[10].b,0)}
    }
    // edges and surfedges of the face
    for e in ([5][2]int{{0,0},{0,1},{1,2},{2,3},{3,0}}) {put_u16(&lumps[12],e[0]);put_u16(&lumps[12],e[1])}
    for se in ([4]int{1,2,3,4}) {put_i32(&lumps[13],se)}
    // model 0
    for v in ([9]f64{0,0,0,64,64,64,0,0,0}) {put_f32(&lumps[14],v)}
    put_i32(&lumps[14],0)
    for _ in 0..<6 {put_i32(&lumps[14],0)}
    out:Bytes
    put_i32(&out,30)
    at:=4+LUMPS*8
    for l in lumps {put_i32(&out,at);put_i32(&out,len(l.b));at+=len(l.b)}
    for l in lumps {append(&out.b,..l.b[:])}
    return out.b[:]
}
