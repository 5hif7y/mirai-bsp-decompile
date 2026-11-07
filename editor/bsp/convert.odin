package bsp_decompile_bsp

import formats "../../../map_convert/editor/formats"
import mapfile "../../../valve220/editor/mapfile"

// A BSP of Quake (29), GoldSrc (30) or BSP2, decompiled to brushes.

Convert_Result :: struct {
    m:mapfile.Map,
    textures:[]formats.Miptex, // the ones the BSP keeps inside; a name only for those kept in a WAD
    kind:string,
    message:string,
}

// The first bytes of a BSP this plugin reads.
is_quake_bsp :: proc(head:[]u8) -> bool {
    if len(head)<4 {return false}
    return string(head[:4])=="BSP2" || (head[0]==29 || head[0]==30) && head[1]==0 && head[2]==0 && head[3]==0
}

convert :: proc(bytes:[]u8,options:Decompile_Options,allocator:=context.allocator) -> (r:Convert_Result,ok:bool) {
    context.allocator=allocator
    if !is_quake_bsp(bytes) {
        r.message="not a BSP of Quake, GoldSrc or BSP2"
        return
    }
    bsp,message,read:=quake_bsp_read(bytes)
    if !read {r.message=message;return r,false}
    switch bsp.version {
    case .Quake:   r.kind="Quake BSP 29"
    case .GoldSrc: r.kind="GoldSrc BSP 30"
    case .BSP2:    r.kind="Quake BSP2"
    }
    r.m,r.textures,ok=decompile_quake(&bsp,options)
    if !ok {r.message="the BSP could not be decompiled"}
    return
}
