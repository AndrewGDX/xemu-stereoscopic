if metal.found()

iosurface = dependency('appleframeworks', modules: ['IOSurface', 'CoreVideo'])

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
	'mtl_c_api.m',
)

foreach f : mtl_sources
	specific_ss.add([metal, iosurface, f])
endforeach

endif
