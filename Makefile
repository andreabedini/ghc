export GHC0   ?= ghc-9.8.4
export CABAL0 ?= _stage0/bin/cabal

STAGE_DIR = $(abspath _$(STAGE))

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
	cabal install --project-dir libraries/Cabal --installdir $(abspath $(@D)) --overwrite-policy=always cabal-install:exe:cabal

PROJECT_FILE = cabal.project.$(STAGE)

define STAGE_RULES
$(let EXES,$(addprefix $(STAGE_DIR)/bin/,$($(STAGE)_TARGETS)),
.PHONY: $(STAGE)
$(STAGE)_EXES = $(EXES) 
$(STAGE): $(EXES)
$(EXES) &: $(CABAL0) $(PROJECT_FILE) $(CONFIGURE)
	$(CABAL0) $(CABAL_ARGS) install --project-file $(PROJECT_FILE) --installdir $(STAGE_DIR)/bin --overwrite-policy=always $(addprefix exe:,$($(STAGE)_TARGETS))\
)
endef

STAGE = stage1
stage1_TARGETS = ghc ghc-toolchain-bin
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
