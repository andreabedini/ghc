export GHC0   ?= ghc-9.8.4
export CABAL0 ?= _stage0/bin/cabal

STAGE     = 1
STAGE_DIR = _stage$(STAGE)

CABAL_ARGS += --store-dir $(abspath $(STAGE_DIR)/store)
CABAL_ARGS += --logs-dir $(abspath $(STAGE_DIR)/logs)

GHC = $(STAGE_DIR)/bin/ghc

all: $(CABAL)
	./Build.hs

CONFIGURE_AC := $(shell git ls-files '**/configure.ac')
CONFIGURE    := $(CONFIGURE_AC:%.ac=)

$(CONFIGURE) : % : %.ac
	autoreconf -i -Wall $(@D)

$(CABAL0):
	mkdir -p $(@D)
	cabal install --project-dir libraries/Cabal --installdir $(abspath $(@D)) cabal-install:exe:cabal

STAGE1_EXES += ghc unlit

define STAGE_RULES
STAGE$(STAGE)_TARGETS += $(addprefix $(STAGE_DIR)/bin/,$(STAGE$(STAGE)_EXES))

.PHONY: stage$(STAGE)
stage$(STAGE): $$(STAGE$(STAGE)_TARGETS)

$$(STAGE$(STAGE)_TARGETS) &: $(CABAL0) $(CONFIGURE)
	$(CABAL0) $(CABAL_ARGS) install --project-file cabal.project.stage$(STAGE) --installdir $$(abspath $$(@D)) $(addprefix exe:,$(STAGE$(STAGE)_EXES))
endef

STAGE = 1
$(eval $(STAGE_RULES))

clean:
	rm -rf _build
	rm -rf _stage*
	rm -rf dist-newstyle

test: all
	TEST_HC=`pwd`/_build/bindist/bin/ghc \
	METRICS_FILE=`pwd`/_build/test-perf.csv \
	SUMMARY_FILE=`pwd`/_build/test-summary.txt \
	JUNIT_FILE=`pwd`/_build/test-junit.xml \
	make -C testsuite/tests test
