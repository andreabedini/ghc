setTestOpts(
  [ req_cmm
  ])

test('selfloop', [cmm_src], compile, ['-no-hs-main'])
test('cmm_sink_sp', [ only_ways(['optasm']),
                      grep_errmsg(r'(\[Sp.*\]).*(=).*(\[.*R1.*\]).*;',[1,2,3]),
                      cmm_src], compile, ['-no-hs-main -ddump-cmm -dsuppress-uniques -O'])

test('T16930', normal, makefile_test, ['T16930'])
test('T17442', normal, compile, [''])
test('T20725', normal, compile, ['-package ghc'])
test('T23610', normal, makefile_test, ['T23610'])
test('T24224', [cmm_src, grep_errmsg(r'(F64.*);', [1]), only_ways(['normal'])], compile, ['-no-hs-main -ddump-cmm -dsuppress-all -dsuppress-uniques'])
test('T24474', cmm_src, compile, ['-optc-g3'])
# Grep for a `... = + .. 42 ..;` occurence from within the dead code block in the cmm dump output.
test('T27368-ppr-debug', [cmm_src, only_ways(['normal']), grep_errmsg(r'\=.*\+.*(42;)', [1])],
     compile, ['-no-hs-main -ddump-cmm-verbose-by-proc -dppr-debug'])
test('T24474-cmm-gets-c-opts', cmm_src, compile, ['-optc-DFOO'])
test('T24474-cmm-opt-order', cmm_src, compile, ['-optc-DFOO '
                                                '-optCmmP-UFOO '
                                                '-optCmmP-UBAR '
                                                '-optc-DBAR'])

# See Note [Cmm target attributes] in GHC.Cmm.
# 256-bit vectors need AVX2, so with no -mavx2 on the command line this only
# compiles if the attribute reaches the code generator.
# NB: unregisterised builds route Cmm through the C backend, which rejects the
# attribute, so this must not run there.
test('CmmTargetAttr',
     [cmm_src,
      unless(arch('x86_64') or arch('i386'), skip),
      when(unregisterised(), skip)],
     compile, [''])

# The LLVM backend must emit a function-level "target-features" attribute.
# NB: that attribute replaces llc's -mattr for the function, so it has to
# repeat the module-wide features.
test('CmmTargetAttrLlvm',
     [cmm_src,
      grep_errmsg(r'(target-features)', [1]),
      unless(arch('x86_64') or arch('i386'), skip),
      when(unregisterised(), skip),
      unless(have_llvm(), skip),
      only_ways(llvm_ways)],
     compile, ['-ddump-llvm'])
