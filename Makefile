all: prod

.PHONY: all dev prod js wasm-dev wasm-prod test clean

.SECONDARY:

MAKEFLAGS += --no-builtin-rules

wasm_path := src/wasm
js_path := src
js_build_path := dist
wasm_publish_path := wasm

wasm_build_path := $(wasm_path)/build
wasm_dev_path := $(wasm_path)/build-dev

lame_src_path := $(wasm_path)/lame/lame-src
ogg_src_path := $(wasm_path)/vorbis/ogg-src
vorbis_src_path := $(wasm_path)/vorbis/vorbis-src

yarn := node .yarn/releases/yarn-berry.cjs

js_output := index.js es/index.js esnext/index.mjs browser/index.js umd/WasmMediaEncoder.min.js
js_output := $(addprefix $(js_build_path)/,$(js_output))

wasm_output := ogg.wasm mp3.wasm

# Setting .SECONDARY should obviate this line but for some reason it doesn't...
.INTERMEDIATE: $(wasm_dev_path)/ogg_full.wasm.map $(wasm_dev_path)/mp3_full.wasm.map 

wasm-dev : emcc_flags := -O0 -g
wasm-dev : emcc_linker_flags := -O0 -g4 --source-map-base file:/$(abspath $(wasm_dev_path))
dev : export NODE_ENV := development
wasm-prod : emcc_flags := -Oz -flto
wasm-prod : emcc_linker_flags := -Oz -flto -Wl,--strip-all
prod : export NODE_ENV := production

wasm-dev: $(addprefix $(wasm_dev_path)/,$(wasm_output) $(wasm_output:=.map))
wasm-prod: $(addprefix $(wasm_build_path)/,$(wasm_output)) $(addprefix $(wasm_publish_path)/,$(wasm_output))
js: $(js_output)

dev: wasm-dev js
prod: wasm-prod js

test: prod
	$(yarn) run jest

$(wasm_publish_path)/%.wasm : $(wasm_build_path)/%.wasm | $(wasm_publish_path)
	cp $< $@

$(wasm_publish_path) $(js_build_path):
	mkdir -p $@

$(wasm_path)/%/:
	mkdir -p $@

$(lame_src_path)/%/lib/libmp3lame.a: | $(lame_src_path)/%/
	cd $(lame_src_path)/$* && \
	emconfigure ../configure \
		CFLAGS="-DNDEBUG -DNO_STDIO $(emcc_flags)" \
		LDFLAGS="$(emcc_flags)" \
		--prefix="$(abspath $(lame_src_path)/$*)" \
		--disable-shared \
		--disable-gtktest \
		--disable-analyzer-hooks \
		--disable-decoder \
		--disable-frontend && \
	emmake make -j8 && \
	emmake make install

define build_full_wasm
	emcc $(filter %.c %.a,$^) \
	  -DNDEBUG $(emcc_linker_flags) \
		$(addprefix -I,$(includes)) \
		--no-entry \
		-s MALLOC=emmalloc \
		-s ALLOW_MEMORY_GROWTH \
		-s STANDALONE_WASM \
		-s NO_SUPPORT_ERRNO \
		-o $(@:.map=)
endef

$(wasm_path)/%/ogg_full.wasm $(wasm_path)/%/ogg_full.wasm.map : includes = $(ogg_src_path)/$*/include $(vorbis_src_path)/$*/include
$(wasm_path)/%/mp3_full.wasm $(wasm_path)/%/mp3_full.wasm.map : includes = $(lame_src_path)/$*/include

$(wasm_path)/%/ogg_full.wasm $(wasm_path)/%/ogg_full.wasm.map : \
	$(ogg_src_path)/%/lib/libogg.a \
	$(vorbis_src_path)/%/lib/libvorbis.a \
	$(vorbis_src_path)/%/lib/libvorbisenc.a \
	$(wasm_path)/vorbis/vorbis_enc.c \
	$(wasm_path)/common_params.h \
	| $(wasm_path)/%/
	$(build_full_wasm)

$(wasm_path)/%/mp3_full.wasm $(wasm_path)/%/mp3_full.wasm.map : \
	$(lame_src_path)/%/lib/libmp3lame.a \
	$(wasm_path)/lame/lame_enc.c \
	$(wasm_path)/common_params.h \
	| $(wasm_path)/%/
	$(build_full_wasm)

$(wasm_dev_path)/%.wasm.map : $(wasm_dev_path)/%_full.wasm.map
	mv $< $@

$(ogg_src_path)/%/lib/libogg.a: | $(ogg_src_path)/%/
	cd $(ogg_src_path)/$* && \
	emcmake cmake .. \
		-DCMAKE_INSTALL_PREFIX=$(abspath $(ogg_src_path)/$*) \
		-DCMAKE_C_FLAGS="$(emcc_flags)" \
		-DCMAKE_MODULE_LINKER_FLAGS_INIT="$(emcc_flags)" \
		&& \
	cmake --build . --target install

$(vorbis_src_path)/%/lib/libvorbis.a $(vorbis_src_path)/%/lib/libvorbisenc.a: \
	$(ogg_src_path)/%/lib/libogg.a \
	| $(vorbis_src_path)/%/

	cd $(vorbis_src_path)/$* && \
	emcmake cmake .. \
		-DCMAKE_INSTALL_PREFIX=$(abspath $(vorbis_src_path)/$*) \
		-DCMAKE_C_FLAGS="$(emcc_flags)" \
		-DCMAKE_MODULE_LINKER_FLAGS_INIT="$(emcc_flags)" \
		-DOGG_INCLUDE_DIR=$(abspath $(ogg_src_path))/$*/include \
		-DOGG_LIBRARY=$(abspath $(ogg_src_path))/$*/lib/libogg.a \
		&& \
	emmake make all install

$(wasm_path)/%.wasm : $(wasm_path)/%_full.wasm $(wasm_path)/minify_graph.json
		/emsdk/upstream/bin/wasm-metadce --graph-file $(wasm_path)/minify_graph.json -o $@ $< && rm $<

# Faking grouped targets

$(js_output) : .sentinel ;

.sentinel : \
	$(js_path)/*.ts \
	$(wasm_path)/*.ts \
	rollup.config.ts \
	tsconfig.json \
	package.json \
	yarn.lock \
	$(wasm_build_path)/ogg.wasm \
	$(wasm_build_path)/mp3.wasm \
	| $(js_build_path)

	$(yarn) run rollup -c
	@touch $@

clean:
	git -C $(ogg_src_path) clean -fxd && \
	git -C $(vorbis_src_path) clean -fxd && \
	git -C $(lame_src_path) clean -fxd && \
	rm -rf $(wasm_build_path) && \
	rm -rf $(wasm_dev_path) && \
	rm -rf $(wasm_publish_path) && \
	rm -rf $(js_build_path)