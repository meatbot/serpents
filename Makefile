PROJECT = serpents

CONFIG ?= test/test.config

DEPS = eper mixer lager cowboy jiffy sumo_db katana uuid
SELL_DEPS = sync
TEST_DEPS = xref_runner shotgun

dep_katana = git https://github.com/inaka/erlang-katana.git 0.2.5
dep_sumo_db = git https://github.com/inaka/sumo_db.git 0b4f706
dep_cowboy = git https://github.com/extend/cowboy.git 1.0.1
dep_jiffy = git https://github.com/davisp/jiffy.git 0.13.3
dep_eper = git https://github.com/massemanet/eper.git 0.90.0
dep_mixer = git https://github.com/inaka/mixer.git 0.1.2
dep_sync = git https://github.com/inaka/sync.git 0.1
dep_shotgun = git https://github.com/inaka/shotgun.git 0.1.8
dep_xref_runner = git https://github.com/inaka/xref_runner.git 0.2.2
dep_uuid = git git://github.com/okeuday/uuid.git v1.4.0

DIALYZER_DIRS := ebin/
DIALYZER_OPTS := --verbose --statistics -Werror_handling \
                 -Wrace_conditions #-Wunmatched_returns

include erlang.mk

ERLC_OPTS := +'{parse_transform, lager_transform}'
ERLC_OPTS += +warn_unused_vars +warn_export_all +warn_shadow_vars +warn_unused_import +warn_unused_function
ERLC_OPTS += +warn_bif_clash +warn_unused_record +warn_deprecated_function +warn_obsolete_guard +strict_validation
ERLC_OPTS += +warn_export_vars +warn_exported_vars +warn_missing_spec +warn_untyped_record +debug_info

TEST_ERLC_OPTS += +'{parse_transform, lager_transform}'
CT_OPTS += -cover test/${PROJECT}.coverspec -vvv -erl_args -config ${CONFIG}

SHELL_OPTS += -name ${PROJECT}@`hostname` -config ${CONFIG} -s lager -s sync

quicktests: app
	@$(MAKE) --no-print-directory app-build test-dir ERLC_OPTS="$(TEST_ERLC_OPTS)"
	@mkdir -p logs/
	$(gen_verbose) $(CT_RUN) -suite $(addsuffix _SUITE,$(CT_SUITES)) $(CT_OPTS)

erldocs:
	erldocs . -o docs
