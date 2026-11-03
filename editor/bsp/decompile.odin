package bsp_decompile_bsp

import "core:fmt"
import "core:strconv"
import "core:strings"
import mapfile "project:plugins/valve220/editor/mapfile"
import formats "project:plugins/map_convert/editor/formats"

// Brushes back from a compiled BSP of Quake or GoldSrc, the method of the
// decompiler of ericw-tools (bsputil --decompile, GPL; docs/LICENCIAS.md):
//
// 1. Each solid (or water, sky...) leaf of the tree of a model is the region
//    behind the planes on the way to it, and becomes a brush: the planes of the
//    path, those of the bounds of the model, minus those that do not touch it.
// 2. A side of the brush takes the drawn faces of the node of its plane that
//    look the same way, clipped to the brush.
// 3. A side whose faces have different textures is split, through an edge of
//    one of them, until each side has one texture: the brush becomes several.
// 4. A side without a face is hidden: it takes the texture of the side most
//    opposite to it, or skip when no side has one.
//
// The brushes are not the ones of the mapper: the compiler cut them along the
// tree, so a wall of one brush may come back as several.

Decompile_Options :: struct {
    // A side no drawn face touches is hidden. By default it takes the texture
    // of the side most opposite to it, as the decompiler of ericw-tools does,
    // so that the map compiles again as it was; with skip_hidden it is skip,
    // which no engine draws: a map to import, not to compile.
    skip_hidden:bool,
}

@(private="file")
Leaf_Plane :: struct {
    using plane:mapfile.Plane,
    node:int, // the node it comes from, -1 for a bound of the model
}

@(private="file")
Decomp_Face :: struct {
    points:[dynamic][3]f64,
    texinfo:int,
}

@(private="file")
Decomp_Side :: struct {
    plane:Leaf_Plane,
    faces:[dynamic]Decomp_Face,
}

@(private="file")
Decompiler :: struct {
    bsp:^Quake_Bsp,
    m:^mapfile.Map,
    scratch,scratch2:[dynamic][3]f64,
    stack:[dynamic]Leaf_Plane,
    leaves:[dynamic][]Leaf_Plane, // the planes of each leaf to decompile
    leaf_contents:[dynamic]i32,
    textured_split_failures:int,
    skip_hidden:bool,
}

// The planes of each non-empty leaf under node.
@(private="file")
walk_node :: proc(d:^Decompiler,node:int,depth:int) {
    if node<0 || node>=len(d.bsp.nodes) || depth>4096 {return}
    n:=d.bsp.nodes[node]
    if n.plane<0 || n.plane>=len(d.bsp.planes) {return}
    p:=d.bsp.planes[n.plane]
    for front in ([2]bool{true,false}) {
        // Going down the front, the leaf is in front of the plane: its outward plane is the flipped one.
        plane:=mapfile.Plane{p.normal,p.dist}
        if front {plane=mapfile.flip(plane)}
        append(&d.stack,Leaf_Plane{plane,node})
        child:=n.children[0 if front else 1]
        if child<0 {
            leaf:=int(-1-child)
            contents:=d.bsp.leaves[leaf].contents if leaf<len(d.bsp.leaves) else CONTENTS_SOLID
            if contents!=CONTENTS_EMPTY {
                append(&d.leaves,slice_clone(d.stack[:]))
                append(&d.leaf_contents,contents)
            }
        } else {
            walk_node(d,int(child),depth+1)
        }
        pop(&d.stack)
    }
}

@(private="file")
slice_clone :: proc(s:[]Leaf_Plane) -> []Leaf_Plane {
    out:=make([]Leaf_Plane,len(s))
    copy(out,s)
    return out
}

// Removes the planes that do not bound the region behind all of them, and
// those repeated.
@(private="file")
remove_redundant :: proc(d:^Decompiler,planes:^[dynamic]Leaf_Plane) {
    // repeated planes: the first stays
    out:=0
    outer: for i in 0..<len(planes) {
        for j in 0..<out {
            if mapfile.dot(planes[j].normal,planes[i].normal)>0.99999 && abs(planes[j].dist-planes[i].dist)<0.01 {continue outer}
        }
        planes[out]=planes[i]
        out+=1
    }
    resize(planes,out)
    keep:=make([dynamic]bool,len(planes),context.temp_allocator)
    for i in 0..<len(planes) {
        mapfile.winding_from_plane(planes[i],&d.scratch)
        alive:=true
        for j in 0..<len(planes) {
            if i==j {continue}
            if !mapfile.winding_clip_back(d.scratch[:],planes[j],&d.scratch2) {alive=false;break}
            d.scratch,d.scratch2=d.scratch2,d.scratch
        }
        keep[i]=alive
    }
    out=0
    for i in 0..<len(planes) {
        if keep[i] {planes[out]=planes[i];out+=1}
    }
    resize(planes,out)
}

// The drawn faces of the node of plane that look the way it faces, clipped
// behind every other plane of the brush.
@(private="file")
side_faces :: proc(d:^Decompiler,plane:Leaf_Plane,planes:[]Leaf_Plane) -> [dynamic]Decomp_Face {
    faces:=make([dynamic]Decomp_Face,context.temp_allocator)
    if plane.node<0 {return faces}
    n:=d.bsp.nodes[plane.node]
    for i in n.first_face..<n.first_face+n.face_count {
        if i<0 || i>=len(d.bsp.faces) {break}
        f:=d.bsp.faces[i]
        fp:=d.bsp.planes[f.plane]
        normal:=-fp.normal if f.side else fp.normal
        if mapfile.dot(normal,plane.normal)<0.9 {continue}
        if !quake_face_points(d.bsp,f,&d.scratch) {continue}
        clipped:=true
        for other in planes {
            if other.normal==plane.normal && other.dist==plane.dist {continue}
            if !mapfile.winding_clip_back(d.scratch[:],other,&d.scratch2) {clipped=false;break}
            d.scratch,d.scratch2=d.scratch2,d.scratch
        }
        if !clipped || mapfile.winding_area(d.scratch[:])<0.01 {continue}
        face:=Decomp_Face{texinfo=f.texinfo}
        face.points=make([dynamic][3]f64,context.temp_allocator)
        append(&face.points,..d.scratch[:])
        append(&faces,face)
    }
    return faces
}

@(private="file")
needs_split :: proc(side:Decomp_Side) -> bool {
    for f in side.faces {
        if f.texinfo!=side.faces[0].texinfo {return true}
    }
    return false
}

// Clips a side's faces by p: those in front and those behind.
@(private="file")
side_clip :: proc(d:^Decompiler,side:Decomp_Side,p:mapfile.Plane) -> (front,back:Decomp_Side) {
    front.plane,back.plane=side.plane,side.plane
    front.faces=make([dynamic]Decomp_Face,context.temp_allocator)
    back.faces=make([dynamic]Decomp_Face,context.temp_allocator)
    for f in side.faces {
        if mapfile.winding_clip_back(f.points[:],mapfile.flip(p),&d.scratch,0.01) && mapfile.winding_area(d.scratch[:])>0.01 {
            nf:=Decomp_Face{texinfo=f.texinfo}
            nf.points=make([dynamic][3]f64,context.temp_allocator)
            append(&nf.points,..d.scratch[:])
            append(&front.faces,nf)
        }
        if mapfile.winding_clip_back(f.points[:],p,&d.scratch,0.01) && mapfile.winding_area(d.scratch[:])>0.01 {
            nf:=Decomp_Face{texinfo=f.texinfo}
            nf.points=make([dynamic][3]f64,context.temp_allocator)
            append(&nf.points,..d.scratch[:])
            append(&back.faces,nf)
        }
    }
    return
}

// Planes through the edges of a face, facing into it.
@(private="file")
edge_planes :: proc(f:Decomp_Face,out:^[dynamic]mapfile.Plane) {
    clear(out)
    n:=mapfile.winding_normal(f.points[:])
    center:=mapfile.winding_center(f.points[:])
    for i in 0..<len(f.points) {
        a,b:=f.points[i],f.points[(i+1)%len(f.points)]
        normal,length:=mapfile.normalize(mapfile.cross(n,b-a))
        if length<1e-6 {continue}
        p:=mapfile.Plane{normal,mapfile.dot(normal,a)}
        if mapfile.dot(p.normal,center)-p.dist<0 {p=mapfile.flip(p)}
        append(out,p)
    }
}

// Splits brush (its sides) until every side has faces of one texture.
@(private="file")
split_textured :: proc(d:^Decompiler,sides:[]Decomp_Side,out:^[dynamic][]Decomp_Side,depth:int) {
    for side in sides {
        if !needs_split(side) {continue}
        if depth>32 {d.textured_split_failures+=1;break}
        // the split through an edge that leaves the fewest faces, with faces on both halves
        best:mapfile.Plane
        best_count:=max(int)
        candidates:=make([dynamic]mapfile.Plane,context.temp_allocator)
        for f in side.faces {
            edge_planes(f,&candidates)
            for split in candidates {
                front,back:=side_clip(d,side,split)
                if len(front.faces)==0 || len(back.faces)==0 {continue}
                if total:=len(front.faces)+len(back.faces);total<best_count {best_count,best=total,split}
            }
        }
        if best_count==max(int) {d.textured_split_failures+=1;break}
        // The brush in front of the split (inside the face) and behind it.
        front_sides:=make([dynamic]Decomp_Side,context.temp_allocator)
        back_sides:=make([dynamic]Decomp_Side,context.temp_allocator)
        for s in sides {
            f,b:=side_clip(d,s,best)
            append(&front_sides,f)
            append(&back_sides,b)
        }
        append(&front_sides,Decomp_Side{plane={mapfile.flip(best),-1}})
        append(&back_sides,Decomp_Side{plane={best,-1}})
        split_textured(d,front_sides[:],out,depth+1)
        split_textured(d,back_sides[:],out,depth+1)
        return
    }
    append(out,sides)
}

@(private="file")
texture_name :: proc(d:^Decompiler,texinfo:int) -> string {
    if texinfo<0 || texinfo>=len(d.bsp.texinfo) {return ""}
    miptex:=d.bsp.texinfo[texinfo].miptex
    if miptex<0 || miptex>=len(d.bsp.textures) {return ""}
    return d.bsp.textures[miptex].name
}

@(private="file")
contents_texture :: proc(contents:i32) -> string {
    switch contents {
    case CONTENTS_WATER: return "*waterskip"
    case CONTENTS_SLIME: return "*slimeskip"
    case CONTENTS_LAVA:  return "*lavaskip"
    case CONTENTS_SKY:   return "sky"
    case CONTENTS_CLIP:  return "clip"
    }
    return "skip"
}

// The brushes of model, in the entity e. offset: the origin of a brush entity
// that turns (its brushes were compiled around it).
@(private="file")
decompile_model :: proc(d:^Decompiler,model:int,e:^mapfile.Entity,offset:[3]f64,trigger:bool) {
    mdl:=d.bsp.models[model]
    head:=mdl.headnode
    if head<0 || head>=len(d.bsp.nodes) {return}
    clear(&d.leaves);clear(&d.leaf_contents);clear(&d.stack)
    n:=d.bsp.nodes[head]
    for k in 0..<3 {
        plus,minus:[3]f64
        plus[k],minus[k]=1,-1
        append(&d.stack,Leaf_Plane{{plus,n.maxs[k]+1},-1},Leaf_Plane{{minus,-(n.mins[k]-1)},-1})
    }
    walk_node(d,head,0)
    planes:=make([dynamic]Leaf_Plane,context.temp_allocator)
    for leaf,li in d.leaves {
        clear(&planes)
        append(&planes,..leaf)
        remove_redundant(d,&planes)
        if len(planes)<4 {continue}
        sides:=make([dynamic]Decomp_Side,context.temp_allocator)
        for p in planes {append(&sides,Decomp_Side{plane=p,faces=side_faces(d,p,planes[:])})}
        brushes:=make([dynamic][]Decomp_Side,context.temp_allocator)
        split_textured(d,sides[:],&brushes,0)
        for brush_sides in brushes {
            brush:mapfile.Brush
            for s in brush_sides {
                side:=mapfile.Side{plane=s.plane.plane}
                if len(s.faces)>0 {
                    side.texture=texture_name(d,s.faces[0].texinfo)
                    mapfile.side_texture_from_vecs(&side,d.bsp.texinfo[s.faces[0].texinfo].vecs)
                } else {
                    side.u,side.v=mapfile.default_axes(side.plane.normal)
                    side.scale={1,1}
                }
                if trigger {side.texture="aaatrigger" if d.bsp.version==.GoldSrc else "trigger"}
                append(&brush.sides,side)
            }
            // A hidden side takes the texture of the side most opposite to it.
            for &side in brush.sides {
                if side.texture!="" {continue}
                if d.skip_hidden {side.texture="skip";continue}
                best:=-1
                best_dot:=-2.0
                for other,k in brush.sides {
                    if other.texture=="" {continue}
                    if dd:=mapfile.dot(-side.plane.normal,other.plane.normal);dd>best_dot {best,best_dot=k,dd}
                }
                side.texture=brush.sides[best].texture if best>=0 else contents_texture(d.leaf_contents[li])
            }
            if offset!={} {
                for &side in brush.sides {
                    side.plane.dist+=mapfile.dot(side.plane.normal,offset)
                    side.shift.x-=mapfile.dot(offset,side.u)/side.scale.x
                    side.shift.y-=mapfile.dot(offset,side.v)/side.scale.y
                }
            }
            append(&e.brushes,brush)
        }
    }
    if offset!={} {
        // The origin brush GoldSrc needs to turn the entity around offset.
        origin:mapfile.Brush
        for k in 0..<3 {
            for sign in ([2]f64{1,-1}) {
                normal:[3]f64
                normal[k]=sign
                side:=mapfile.Side{plane={normal,8+mapfile.dot(normal,offset)},texture="origin",scale={1,1}}
                side.u,side.v=mapfile.default_axes(normal)
                append(&origin.sides,side)
            }
        }
        append(&e.brushes,origin)
    }
}

// The .map of a compiled BSP of Quake or GoldSrc, and the textures embedded
// in the BSP, for textures_write to unpack beside it.
decompile_quake :: proc(bsp:^Quake_Bsp,options:Decompile_Options,allocator:=context.allocator) -> (m:mapfile.Map,textures:[]formats.Miptex,ok:bool) {
    context.allocator=allocator
    if !mapfile.entities_parse(bsp.entities,&m) || len(m.entities)==0 {
        mapfile.map_warn(&m,"the entity lump could not be read")
        return m,nil,false
    }
    d:=Decompiler{bsp=bsp,m=&m,skip_hidden=options.skip_hidden}
    for &e,i in m.entities {
        model:=-1
        if i==0 {model=0}
        offset:[3]f64
        kept:=make([dynamic][2]string)
        for kv in e.keys {
            if kv[0]=="model" && strings.has_prefix(kv[1],"*") {
                if n,parsed:=strconv.parse_int(kv[1][1:]);parsed {model=n}
                continue
            }
            if kv[0]=="origin" && model>0 {
                parts:=strings.fields(kv[1],context.temp_allocator)
                if len(parts)==3 {
                    for k in 0..<3 {offset[k],_=strconv.parse_f64(parts[k])}
                }
                continue
            }
            append(&kept,kv)
        }
        // "model" comes before "origin" in some entities and after it in others.
        if model>0 && offset=={} {
            for kv in e.keys {
                if kv[0]=="origin" {
                    parts:=strings.fields(kv[1],context.temp_allocator)
                    if len(parts)==3 {for k in 0..<3 {offset[k],_=strconv.parse_f64(parts[k])}}
                    for j in 0..<len(kept) {if kept[j][0]=="origin" {ordered_remove(&kept,j);break}}
                }
            }
        }
        if model<0 {continue}
        e.keys=kept
        if model>=len(bsp.models) {
            mapfile.map_warn(&m,"entity %d names model *%d, which the BSP does not have",i,model)
            continue
        }
        classname,_:=mapfile.entity_get(&e,"classname")
        decompile_model(&d,model,&e,offset,strings.has_prefix(classname,"trigger_"))
    }
    if d.textured_split_failures>0 {
        mapfile.map_warn(&m,"%d brushes kept faces of several textures on one side",d.textured_split_failures)
    }
    embedded:=make([dynamic]formats.Miptex)
    for t in bsp.textures {if t.pixels!=nil {append(&embedded,t)}}
    return m,embedded[:],true
}
