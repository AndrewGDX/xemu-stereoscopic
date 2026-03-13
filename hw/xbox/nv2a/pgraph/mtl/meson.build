if metal.found()

mtl_sources = files(
	'renderer.c',
	'display.m',
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
	'mtl_c_api.m',
)

foreach f : mtl_sources
	specific_ss.add([metal, f])
endforeach

endif
