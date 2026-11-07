package bsp_decompile_editor

import "core:os"
import "core:path/filepath"
import "core:strings"
import importer "mirai:cook/import"
import "mirai:cook/textures"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:std/base"
import "mirai:std/serial"
import bsp "./bsp"
import map_convert "../../map_convert/editor"
import formats "../../map_convert/editor/formats"
import valvemap "../../valve220/editor/loader"
import mapfile "../../valve220/editor/mapfile"

// BSPs of Quake (29), GoldSrc (30) and BSP2 in the import of the editor:
// decompiled to brushes (bsp/decompile.odin), written as Valve 220 in memory
// and read by the loader of valve220, with the textures the BSP keeps inside
// given as texels. A texture kept in a WAD comes from textures/<name>.png
// beside the BSP, as for any map (map_convert.unpack_wad writes them).
//
// The sides no drawn face touches are skip on import: what the outside of
// the map would show. The API writes a .map to edit and compile again, where
// they take the texture of the opposite side unless skip_hidden.

@(private)
read :: proc(c:^importer.Reader,bytes:[]u8) -> bool {
    r,ok:=bsp.convert(bytes,{skip_hidden=true},context.temp_allocator)
    if !ok {return importer.fail(c,.Malformed,"%s",r.message)}
    for warning in r.m.warnings {importer.warn(c,"%s",warning)}
    images:=make(valvemap.Images,context.temp_allocator)
    for m in r.textures {
        if m.pixels==nil || m.name=="" {continue}
        // the textures of Quake keep no palette: their image comes from a file
        rgba,made:=formats.miptex_rgba(m,nil,context.temp_allocator)
        if !made {continue}
        images[m.name]=textures.Source{texels=rgba,width=m.width,height=m.height,format=.RGBA8}
    }
    return valvemap.read_text(c,mapfile.map_write(&r.m,context.temp_allocator),images)
}

@(private)
sniff :: proc(head:[]u8) -> importer.Sniff {
    return .Content if bsp.is_quake_bsp(head) else .No
}

@(storage)
Bsp_Decompile_Format :: struct {provider:editor.Import_Format_Provider}

bsp_decompile_format_default :: proc() -> Bsp_Decompile_Format {
    return {provider={format={name="Quake or GoldSrc BSP",extensions={0=".bsp"},version=0,space=valvemap.FORMAT.space,sniff=sniff,read=read}}}
}

// ---------------------------------------------------------------- the API

@(storage)
Bsp_Decompile_Api :: struct {provider:editor.Api_Provider}

BSP_DECOMPILE_API_DEFAULT :: Bsp_Decompile_Api{provider={register=bsp_decompile_api_register}}

To_Valve220_Params :: struct {
    path:[editor.API_PATH_BYTES]u8 `mirai:"text,label=A BSP of Quake, GoldSrc or BSP2, anywhere on disk; nothing is written into it"`,
    out:[editor.API_PATH_BYTES]u8 `mirai:"text,label=The Valve 220 .map to write, relative to the project; the textures the BSP keeps go to textures/ beside it as PNG"`,
    skip_hidden:bool `mirai:"optional,label=The sides no drawn face touches are skip: a map to import, not to compile again"`,
}

To_Valve220_Result :: struct {
    kind:[64]u8 `mirai:"text,label=What the input was"`,
    brushes:int `mirai:"label=Brushes written"`,
    textures:int `mirai:"label=Textures written as PNG"`,
}

@(private)
bsp_decompile_api_register :: proc(s:^editor.Session) {
    editor.api_method_register(s,{name="bsp_decompile.to_valve220",summary="Decompiles a BSP of Quake, GoldSrc or BSP2 to a Valve 220 .map in the project, with the textures it keeps inside as PNG beside it.",params=To_Valve220_Params,params_info=type_info_of(To_Valve220_Params),result=To_Valve220_Result,result_info=type_info_of(To_Valve220_Result),run=api_to_valve220})
}

@(private)
api_to_valve220 :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,To_Valve220_Params)
    source:=base.text_get(p.path[:])
    out,ok:=map_convert.project_file(s,call,base.text_get(p.out[:]),"out")
    if !ok {return}
    bytes,error:=serial.file_read(source,context.temp_allocator)
    if error!=.None {api.call_failf(call,api.INVALID_PARAMS,"path %q could not be read",source);return}
    r,converted:=bsp.convert(bytes,{skip_hidden=p.skip_hidden},context.temp_allocator)
    if !converted {api.call_failf(call,api.INVALID_PARAMS,"%s: %s",source,r.message);return}
    folder:=filepath.dir(out)
    os.make_directory_all(folder)
    if os.write_entire_file(out,transmute([]u8)mapfile.map_write(&r.m,context.temp_allocator))!=nil {api.call_failf(call,api.SERVER_ERROR,"%s could not be written",out);return}
    written,_,_:=formats.textures_write(r.textures,strings.concatenate({folder,"/textures"},context.temp_allocator))
    result:=api.call_result(call,To_Valve220_Result)
    base.text_set(result.kind[:],r.kind)
    for e in r.m.entities {result.brushes+=len(e.brushes)}
    result.textures=written
}
