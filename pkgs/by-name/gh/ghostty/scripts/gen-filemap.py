#!/usr/bin/env python3
"""
Generate an output-file-map.json for swiftc so that per-source .o files
land in the build directory we control.

Usage: gen-filemap.py <build-dir> <source.swift> [<source.swift> ...]
"""
import json, os, sys

build_dir = sys.argv[1]
omap = {}
for path in sys.argv[2:]:
    name = os.path.splitext(os.path.basename(path))[0]
    omap[path] = {'object': build_dir + '/swift-objs/' + name + '.o'}
empty = str()
omap[empty] = {'swift-dependencies': build_dir + '/swift-objs/Ghostty-master.swiftdeps'}
print(json.dumps(omap, indent=2))
