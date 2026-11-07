package bsp_decompile_bsp

import "core:encoding/endian"
import "core:fmt"
import "core:math/linalg"
import "core:os"
import "core:strings"
import "core:testing"
import importer "mirai:cook/import"
import mapfile "../../../valve220/editor/mapfile"
import valvemap "../../../valve220/editor/loader"

// Each test makes the same cube, [0,64] in map units, in one format, converts
// it and imports the .map with the loader: 12 triangles between 0 and 2 m.

@(private="file")
Bytes :: struct {b:[dynamic]u8}


@(private="file")
put_i32 :: proc(w:^Bytes,v:int) {x:[4]u8;endian.put_i32(x[:],.Little,i32(v));append(&w.b,..x[:])}

@(private="file")
put_u16 :: proc(w:^Bytes,v:int) {x:[2]u8;endian.put_u16(x[:],.Little,u16(v));append(&w.b,..x[:])}

@(private="file")
put_i16 :: proc(w:^Bytes,v:int) {x:[2]u8;endian.put_i16(x[:],.Little,i16(v));append(&w.b,..x[:])}

@(private="file")
put_f32 :: proc(w:^Bytes,v:f64) {x:[4]u8;endian.put_f32(x[:],.Little,f32(v));append(&w.b,..x[:])}

@(private="file")
put_name :: proc(w:^Bytes,name:string,size:int) {
    x:=make([]u8,size,context.temp_allocator)
    copy(x,name)
    append(&w.b,..x)
}


// The six outward planes of the cube: +x -x +y -y +z -z.
@(private="file")
CUBE_PLANES :: [6]mapfile.Plane{{{1,0,0},64},{{-1,0,0},0},{{0,1,0},64},{{0,-1,0},0},{{0,0,1},64},{{0,0,-1},0}}


@(private="file")
import_converted :: proc(t:^testing.T,m:^mapfile.Map,name:string) -> (triangles:int,lo,hi:[3]f32,materials:[]string) {
    directory,_:=os.temp_directory(context.temp_allocator)
    folder:=fmt.tprintf("%s/mirai-mapconvert-%d-%s",directory,os.get_pid(),name)
    os.remove_all(folder)
    os.make_directory_all(folder)
    defer os.remove_all(folder)
    path:=fmt.tprintf("%s/%s.map",folder,name)
    text:=mapfile.map_write(m,context.temp_allocator)
    _=os.write_entire_file(path,transmute([]u8)text)
    formats:=[?]importer.Format{valvemap.FORMAT}
    model,error:=importer.import_model(path,formats[:],{})
    if !testing.expectf(t,error.code==.None,"%s: %v %s\n%s",name,error.code,error.message,text) {return}
    defer importer.model_destroy(&model)
    lo,hi={1e9,1e9,1e9},{-1e9,-1e9,-1e9}
    for mesh in model.meshes {
        triangles+=len(mesh.indices)/3
        lo=linalg.min(lo,mesh.bounds_min)
        hi=linalg.max(hi,mesh.bounds_max)
    }
    names:=make([dynamic]string,context.temp_allocator)
    for mat in model.materials {append(&names,strings.clone(mat.name,context.temp_allocator))}
    return triangles,lo,hi,names[:]
}


@(private="file")
expect_cube :: proc(t:^testing.T,m:^mapfile.Map,name:string,loc:=#caller_location) {
    triangles,lo,hi,_:=import_converted(t,m,name)
    testing.expectf(t,triangles==12,"%s: %d triangles",name,triangles,loc=loc)
    // 32 map units to the meter, Z up turned to Y up, +Y map is -Z.
    testing.expectf(t,linalg.length(lo-[3]f32{0,0,-2})<1e-4 && linalg.length(hi-[3]f32{2,2,0})<1e-4,
        "%s: bounds %v %v",name,lo,hi,loc=loc)
}


// A BSP 30 whose tree is six nodes, one per plane: the front of each is an
// empty leaf and the back of the last the solid one. One face, on +z, says
// the texture.
@(private="file")
goldsrc_cube_bsp :: proc() -> []u8 {
    lumps:[QUAKE_LUMPS]Bytes
    entities:="{\n\"classname\" \"worldspawn\"\n\"wad\" \"\"\n}\n\x00"
    append(&lumps[0].b,..transmute([]u8)entities)
    planes:=CUBE_PLANES
    for p in planes {
        put_f32(&lumps[1],p.normal.x);put_f32(&lumps[1],p.normal.y);put_f32(&lumps[1],p.normal.z)
        put_f32(&lumps[1],p.dist);put_i32(&lumps[1],0)
    }
    // textures: one miptex kept in a WAD (offsets 0)
    put_i32(&lumps[2],1);put_i32(&lumps[2],8)
    put_name(&lumps[2],"CRATE",16);put_i32(&lumps[2],64);put_i32(&lumps[2],64)
    for _ in 0..<4 {put_i32(&lumps[2],0)}
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
    for contents in ([3]int{CONTENTS_SOLID,CONTENTS_EMPTY,CONTENTS_SOLID}) {
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
    at:=4+QUAKE_LUMPS*8
    for l in lumps {put_i32(&out,at);put_i32(&out,len(l.b));at+=len(l.b)}
    for l in lumps {append(&out.b,..l.b[:])}
    return out.b[:]
}


@(test)
a_goldsrc_bsp_decompiles_to_its_brush :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    r,ok:=convert(goldsrc_cube_bsp(),{},context.temp_allocator)
    if !testing.expectf(t,ok,"%s",r.message) {return}
    testing.expect_value(t,r.kind,"GoldSrc BSP 30")
    testing.expect_value(t,len(r.m.entities),1)
    if !testing.expect_value(t,len(r.m.entities[0].brushes),1) {return}
    brush:=r.m.entities[0].brushes[0]
    // the bounds of the model are redundant: the six planes of the cube remain
    testing.expect_value(t,len(brush.sides),6)
    for side in brush.sides {
        // the face on +z gives its texture to every side; the opposite one by being opposite
        testing.expect_value(t,side.texture,"CRATE")
        if side.plane.normal.z>0.5 {testing.expect(t,side.u==[3]f64{1,0,0} && side.v==[3]f64{0,-1,0})}
    }
    expect_cube(t,&r.m,"goldsrc")
}


@(test)
skip_hidden_leaves_the_sides_without_a_face_undrawn :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    r,ok:=convert(goldsrc_cube_bsp(),{skip_hidden=true},context.temp_allocator)
    if !testing.expect(t,ok) {return}
    textured:=0
    for side in r.m.entities[0].brushes[0].sides {if side.texture=="CRATE" {textured+=1}}
    testing.expect_value(t,textured,1)
    triangles,_,_,_:=import_converted(t,&r.m,"skip")
    testing.expect_value(t,triangles,2)
}

