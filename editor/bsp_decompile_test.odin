package bsp_decompile_editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import importer "mirai:cook/import"
import fixture "project:plugins/bsp_decompile/editor/fixture"
import valve220 "project:plugins/valve220/editor"

@(private="file")
temp_folder :: proc(name:string) -> string {
    directory,_:=os.temp_directory(context.temp_allocator)
    path,_:=strings.replace_all(fmt.tprintf("%s/mirai-bsp-decompile-%d-%s",directory,os.get_pid(),name),"\\","/",context.temp_allocator)
    os.remove_all(path)
    os.make_directory_all(path)
    return path
}

// A BSP of GoldSrc with its texture inside imports through the format of the
// plugin: the brush of the cube, its hidden sides skip, and the material takes
// the pixels of the BSP, with no PNG beside it.
@(test)
a_goldsrc_bsp_imports_with_the_texture_it_keeps :: proc(t:^testing.T) {
    folder:=temp_folder("embedded")
    defer os.remove_all(folder)
    path:=fmt.tprintf("%s/cube.bsp",folder)
    testing.expect(t,os.write_entire_file(path,fixture.cube_bsp(embedded=true,allocator=context.temp_allocator))==nil)
    formats:=[?]importer.Format{valve220.valve220_format_default().provider.format,bsp_decompile_format_default().provider.format}
    found,known:=importer.format_find(formats[:],fixture.cube_bsp(allocator=context.temp_allocator),".bsp")
    testing.expect(t,known && found.name=="Quake or GoldSrc BSP")
    model,error:=importer.import_model(path,formats[:],{})
    if !testing.expectf(t,error.code==.None,"%v %s",error.code,error.message) {return}
    defer importer.model_destroy(&model)
    triangles:=0
    for mesh in model.meshes {triangles+=len(mesh.indices)/3}
    // only the face the BSP draws: the other five sides are hidden, and skip
    testing.expect_value(t,triangles,2)
    if !testing.expect_value(t,len(model.images),1) {return}
    image:=model.images[0]
    testing.expect(t,image.path=="" && image.made.width==64 && image.made.height==64,"the image is the texels of the BSP, not a file")
    color:=fixture.EMBEDDED_COLOR
    testing.expect(t,len(image.made.texels)>=4 && image.made.texels[0]==color.r && image.made.texels[1]==color.g && image.made.texels[2]==color.b,"the palette of the BSP gives the color")
}
