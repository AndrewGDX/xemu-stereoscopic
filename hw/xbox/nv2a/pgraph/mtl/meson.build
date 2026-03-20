if metal.found()

mtl_sources = files(
	'renderer.c',
	'display.m',
	'display_mtl.mm',
	'surface.m',
	'texture.m',
	'shaders.m',
	'vertex.m',
	'draw.m',
	'buffer.m',
	'command.m',
	'blit.m',
	'reports.m',
	'gpuprops.m',
	'instance.m',
)

foreach f : mtl_sources
	specific_ss.add([metal, f])
endforeach

endif
