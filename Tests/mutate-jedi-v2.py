#!/usr/bin/env python3
"""Behavioral mutation checks for exact-stock recognition and atomic Retina upgrade.
Scratch-only sources. A compile/resource failure or crash is an error, not a kill.
"""
import os, pathlib, shutil, subprocess, sys, tempfile
root = pathlib.Path(sys.argv[1]).resolve()
mutants = [
 ('ignore-custom-cast', 'let oldFiles = referencedPNGs(oldPoses)', 'let oldFiles = Set(oldPoses.values.compactMap { $0["file"] as? String })', 'custom alternate layer overwritten'),
 ('omit-retina-transaction', 'for (poseName, row) in sourceRows {\n                guard let retinaJSON', 'for (poseName, row) in sourceRows where false {\n                guard let retinaJSON', 'missing Retina accepted'),
]
with tempfile.TemporaryDirectory(prefix='jedi-v2-mutants-',dir='/tmp') as temp:
 work=pathlib.Path(temp); original=(root/'Sources/Models.swift').read_text(); model=work/'Models.swift'
 def run(source):
  model.write_text(source);binary=work/'check'
  subprocess.run([str(root/'Tests/compile-guard.sh'),'swiftc','-target','arm64-apple-macosx14.0','-swift-version','6','-strict-concurrency=complete','-parse-as-library',str(model),str(root/'Tests/JediV2MigrationCheck.swift'),'-framework','AppKit','-o',str(binary)],check=True)
  return subprocess.run([str(binary),str(root)],capture_output=True,text=True)
 baseline=run(original);print(baseline.stdout,baseline.stderr,flush=True);assert baseline.returncode==0,'baseline not green'
 for name,old,new,reason in mutants:
  assert original.count(old)==1,(name,'target count')
  result=run(original.replace(old,new));assert result.returncode==1 and reason in result.stderr,(name,result.returncode,result.stderr[-1500:])
  print('KILLED',name,reason,flush=True)
 print('PASS 2 behavioral mutants, baseline green',flush=True)
