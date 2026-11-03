package bsp_decompile_bsp

import "core:encoding/endian"
import mapfile "project:plugins/valve220/editor/mapfile"
import formats "project:plugins/map_convert/editor/formats"

// The BSP of Quake (version 29), of GoldSrc (30, Half-Life and Counter-Strike)
// and BSP2 (Quake maps beyond the limits of 29): a header of 15 lumps. A
// compiled map keeps no brushes: the world is a tree of planes whose leaves
// are convex regions marked solid, empty, water... and the faces that are
// drawn. decompile.odin turns the solid leaves back into brushes.

Quake_Version :: enum u8 {Quake,GoldSrc,BSP2}


QUAKE_LUMPS :: 15

CONTENTS_EMPTY :: -1

CONTENTS_SOLID :: -2

CONTENTS_WATER :: -3

CONTENTS_SLIME :: -4

CONTENTS_LAVA :: -5

CONTENTS_SKY :: -6

CONTENTS_CLIP :: -8 // GoldSrc


Quake_Plane :: struct {normal:[3]f64,dist:f64}


Quake_Node :: struct {
    plane:int,
    children:[2]i32,   // >=0: a node; <0: the leaf -1-child
    mins,maxs:[3]f64,
    first_face,face_count:int,
}


Quake_Leaf :: struct {contents:i32}


Quake_Texinfo :: struct {
    vecs:[2][4]f64, // s and t: axis xyz and offset, in texels per unit
    miptex:int,
}


Quake_Face :: struct {
    plane:int,
    side:bool,      // the face looks along the opposite of its plane
    first_edge,edge_count:int,
    texinfo:int,
}


Quake_Model :: struct {
    mins,maxs,origin:[3]f64,
    headnode:int,
}


Quake_Bsp :: struct {
    version:Quake_Version,
    entities:string,
    planes:[]Quake_Plane,
    textures:[]formats.Miptex, // in the order of the lump; a name only for those kept in a WAD
    vertices:[][3]f64,
    nodes:[]Quake_Node,
    texinfo:[]Quake_Texinfo,
    faces:[]Quake_Face,
    leaves:[]Quake_Leaf,
    edges:[][2]int,
    surfedges:[]i32,
    models:[]Quake_Model,
}


// The bytes of lump i, or false when the header puts them outside the file.
@(private)
quake_lump :: proc(b:[]u8,i:int) -> (lump:[]u8,ok:bool) {
    at:=4+i*8
    offset,length:=int(formats.rd_i32(b,at)),int(formats.rd_i32(b,at+4))
    if offset<0 || length<0 || offset+length>len(b) {return nil,false}
    return b[offset:offset+length],true
}


// Reads the lumps the decompiler needs. The slices point into b, which must
// outlive the result; the arrays are in allocator.
quake_bsp_read :: proc(b:[]u8,allocator:=context.allocator) -> (bsp:Quake_Bsp,message:string,ok:bool) {
    context.allocator=allocator
    if len(b)<4+QUAKE_LUMPS*8 {return {},"too short for a BSP header",false}
    switch {
    case string(b[:4])=="BSP2": bsp.version=.BSP2
    case formats.rd_i32(b,0)==29:       bsp.version=.Quake
    case formats.rd_i32(b,0)==30:       bsp.version=.GoldSrc
    case:                       return {},"not a BSP of Quake (29), GoldSrc (30) or BSP2",false
    }
    wide:=bsp.version==.BSP2
    lumps:[QUAKE_LUMPS][]u8
    for i in 0..<QUAKE_LUMPS {
        lump,read:=quake_lump(b,i)
        if !read {return {},"a lump lies outside the file",false}
        lumps[i]=lump
    }
    entities:=lumps[0]
    for len(entities)>0 && entities[len(entities)-1]==0 {entities=entities[:len(entities)-1]}
    bsp.entities=string(entities)

    planes:=lumps[1]
    bsp.planes=make([]Quake_Plane,len(planes)/20)
    for &p,i in bsp.planes {
        at:=i*20
        p={{formats.rd_f32(planes,at),formats.rd_f32(planes,at+4),formats.rd_f32(planes,at+8)},formats.rd_f32(planes,at+12)}
    }

    textures:=lumps[2]
    if len(textures)>=4 {
        count:=int(formats.rd_i32(textures,0))
        if count<0 || 4+count*4>len(textures) {return {},"the texture lump is broken",false}
        list:=make([dynamic]formats.Miptex,0,count)
        for i in 0..<count {
            offset:=int(formats.rd_i32(textures,4+i*4))
            m:formats.Miptex
            if offset>=0 && offset<len(textures) {
                m,_=formats.miptex_read(textures[offset:])
            }
            append(&list,m)
        }
        bsp.textures=list[:]
    }

    vertices:=lumps[3]
    bsp.vertices=make([][3]f64,len(vertices)/12)
    for &v,i in bsp.vertices {v={formats.rd_f32(vertices,i*12),formats.rd_f32(vertices,i*12+4),formats.rd_f32(vertices,i*12+8)}}

    nodes:=lumps[5]
    node_size:=44 if wide else 24
    bsp.nodes=make([]Quake_Node,len(nodes)/node_size)
    for &n,i in bsp.nodes {
        at:=i*node_size
        n.plane=int(formats.rd_i32(nodes,at))
        if wide {
            n.children={formats.rd_i32(nodes,at+4),formats.rd_i32(nodes,at+8)}
            for k in 0..<3 {n.mins[k]=formats.rd_f32(nodes,at+12+k*4);n.maxs[k]=formats.rd_f32(nodes,at+24+k*4)}
            n.first_face,n.face_count=int(formats.rd_u32(nodes,at+36)),int(formats.rd_u32(nodes,at+40))
        } else {
            n.children={i32(formats.rd_i16(nodes,at+4)),i32(formats.rd_i16(nodes,at+6))}
            for k in 0..<3 {n.mins[k]=f64(formats.rd_i16(nodes,at+8+k*2));n.maxs[k]=f64(formats.rd_i16(nodes,at+14+k*2))}
            n.first_face,n.face_count=formats.rd_u16(nodes,at+20),formats.rd_u16(nodes,at+22)
        }
    }

    texinfo:=lumps[6]
    bsp.texinfo=make([]Quake_Texinfo,len(texinfo)/40)
    for &t,i in bsp.texinfo {
        at:=i*40
        for s in 0..<2 {for k in 0..<4 {t.vecs[s][k]=formats.rd_f32(texinfo,at+s*16+k*4)}}
        t.miptex=int(formats.rd_i32(texinfo,at+32))
    }

    faces:=lumps[7]
    face_size:=28 if wide else 20
    bsp.faces=make([]Quake_Face,len(faces)/face_size)
    for &f,i in bsp.faces {
        at:=i*face_size
        if wide {
            f={int(formats.rd_i32(faces,at)),formats.rd_i32(faces,at+4)!=0,int(formats.rd_i32(faces,at+8)),int(formats.rd_i32(faces,at+12)),int(formats.rd_i32(faces,at+16))}
        } else {
            f={formats.rd_u16(faces,at),formats.rd_u16(faces,at+2)!=0,int(formats.rd_i32(faces,at+4)),formats.rd_u16(faces,at+8),formats.rd_u16(faces,at+10)}
        }
    }

    leaves:=lumps[10]
    leaf_size:=44 if wide else 28
    bsp.leaves=make([]Quake_Leaf,len(leaves)/leaf_size)
    for &l,i in bsp.leaves {l.contents=formats.rd_i32(leaves,i*leaf_size)}

    edges:=lumps[12]
    edge_size:=8 if wide else 4
    bsp.edges=make([][2]int,len(edges)/edge_size)
    for &e,i in bsp.edges {
        if wide {e={int(formats.rd_u32(edges,i*8)),int(formats.rd_u32(edges,i*8+4))}} else {e={formats.rd_u16(edges,i*4),formats.rd_u16(edges,i*4+2)}}
    }

    surfedges:=lumps[13]
    bsp.surfedges=make([]i32,len(surfedges)/4)
    for &s,i in bsp.surfedges {s=formats.rd_i32(surfedges,i*4)}

    models:=lumps[14]
    bsp.models=make([]Quake_Model,len(models)/64)
    for &m,i in bsp.models {
        at:=i*64
        for k in 0..<3 {
            m.mins[k]=formats.rd_f32(models,at+k*4)
            m.maxs[k]=formats.rd_f32(models,at+12+k*4)
            m.origin[k]=formats.rd_f32(models,at+24+k*4)
        }
        m.headnode=int(formats.rd_i32(models,at+36))
    }
    if len(bsp.models)==0 || len(bsp.nodes)==0 || len(bsp.planes)==0 {return {},"the BSP has no world",false}
    return bsp,"",true
}


// The corners of a face, in the order of its edges.
quake_face_points :: proc(bsp:^Quake_Bsp,f:Quake_Face,out:^[dynamic][3]f64) -> bool {
    clear(out)
    for i in 0..<f.edge_count {
        at:=f.first_edge+i
        if at<0 || at>=len(bsp.surfedges) {return false}
        se:=bsp.surfedges[at]
        edge:=int(abs(se))
        if edge>=len(bsp.edges) {return false}
        v:=bsp.edges[edge][1] if se<0 else bsp.edges[edge][0]
        if v>=len(bsp.vertices) {return false}
        append(out,bsp.vertices[v])
    }
    return len(out)>=3
}

