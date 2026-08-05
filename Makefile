# Rebuild every derived artefact in dependency order.
#
# WHY THIS EXISTS
# The submission ships generated media — charts, screenshots, a slide deck and
# a video — and each is downstream of the hardware artefacts. Regenerating them
# by hand meant they drifted independently: on 2026-08-02 the demo video was
# from 31 May, the screenshots inside it showed a run superseded twice, and
# outputs/p_optimal.png carried a hardcoded "+23% lift" headline from 22 May
# that the data no longer supported. Each was found by chance.
#
# `make refresh` rebuilds the whole chain so they cannot drift apart, and
# `make verify` gates on the numbers matching the chain and the artefacts.
#
# THE CHAIN
#   outputs/hardware_run*.json      (source of truth — produced by QPU runs)
#     -> outputs/p_optimal.png           make_chart.py
#     -> outputs/hardware_vs_noise*.png  make_hardware_chart.py
#        -> docs/screenshots/*.png       take_screenshots.py  (app.py renders the charts)
#   docs/PITCH_DECK.md
#     -> docs/PITCH_DECK.pdf/.html       marp
#        -> docs/DEMO_VIDEO.mp4          build_demo_video.py  (deck PDF + screenshots)

SHELL   := /bin/bash
PY      := .venv/bin/python
MARP    := marp
CHROME  := $(CURDIR)/chrome/linux-151.0.7922.71/chrome-linux64/chrome
PORT    := 8501

HW_STOCKS := outputs/hardware_run.json
HW_DEFI   := outputs/hardware_run_defi.json
CHARTS    := outputs/p_optimal.png outputs/hardware_vs_noise_stocks.png
SHOTS     := docs/screenshots/04-hardware-verification.png
DECK_PDF  := docs/PITCH_DECK.pdf
DECK_HTML := docs/PITCH_DECK.html
VIDEO     := docs/DEMO_VIDEO.mp4

.PHONY: refresh verify test charts screenshots deck deck-check video clean-procs help

help:
	@echo "make refresh      rebuild charts -> screenshots -> deck -> video, then verify"
	@echo "make verify       check documented claims against chain, artefacts and tests"
	@echo "make test         python + foundry suites"
	@echo "make charts       regenerate outputs/*.png from the hardware artefacts"
	@echo "make screenshots  recapture the Streamlit screenshots (starts/stops the app)"
	@echo "make deck         rebuild PITCH_DECK.pdf and .html from the markdown"
	@echo "make video        rebuild DEMO_VIDEO.mp4 from the deck + screenshots"

## --- charts -------------------------------------------------------------
outputs/p_optimal.png: $(HW_STOCKS) make_chart.py
	$(PY) make_chart.py

outputs/hardware_vs_noise_stocks.png: $(HW_STOCKS) make_hardware_chart.py
	$(PY) make_hardware_chart.py $(HW_STOCKS)
	mv outputs/hardware_vs_noise.png $@
	cp $@ docs/screenshots/09-stocks-mitigation-effect.png
	$(PY) make_hardware_chart.py $(HW_DEFI)
	cp outputs/hardware_vs_noise.png docs/screenshots/08-hardware-vs-noise.png

charts: $(CHARTS)

## --- screenshots (app.py renders p_optimal.png, so charts come first) ----
$(SHOTS): app.py $(CHARTS) $(HW_STOCKS) $(HW_DEFI) scripts/take_screenshots.py
	PY=$(PY) PORT=$(PORT) scripts/refresh_screenshots.sh

screenshots: $(SHOTS)

## --- deck ---------------------------------------------------------------
# marp intermittently hangs; a stale headless chromium is the usual cause.
$(DECK_PDF) $(DECK_HTML): docs/PITCH_DECK.md
	@pkill -9 -f "[c]hrome-linux64" 2>/dev/null || true   # bracket: do not self-match
	CHROME_PATH=$(CHROME) $(MARP) docs/PITCH_DECK.md --pdf  --allow-local-files -o $(DECK_PDF)
	CHROME_PATH=$(CHROME) $(MARP) docs/PITCH_DECK.md --html --allow-local-files -o $(DECK_HTML)
	@# marp CLIPS anything past the fixed 1280x720 frame instead of paginating,
	@# silently dropping a slide's last point. 13 of 18 slides were losing
	@# content before this gate existed. Fail the build rather than ship it.
	$(PY) scripts/check_deck_overflow.py $(DECK_HTML)

deck: $(DECK_PDF) $(DECK_HTML)

deck-check:
	$(PY) scripts/check_deck_overflow.py $(DECK_HTML)

## --- video --------------------------------------------------------------
$(VIDEO): $(DECK_PDF) $(SHOTS) scripts/build_demo_video.py
	$(PY) scripts/build_demo_video.py

video: $(VIDEO)

## --- gates --------------------------------------------------------------
verify:
	$(PY) verify_claims.py --chain

test:
	$(PY) -m pytest tests/ -q
	cd contracts && MONAD_RPC_URL=https://rpc.monad.xyz \
		FORK_TOKEN_OUT=0x754704Bc059F8C67012fEd69BC8A327a5aafb603 \
		FORK_FEE=3000 forge test

# The whole chain, in order, then the gate. Run this after ANY change to a
# hardware artefact, the app, or the deck markdown.
refresh: charts screenshots deck video
	@echo ""
	@echo "all derived artefacts rebuilt — verifying claims"
	@$(MAKE) --no-print-directory verify

clean-procs:
	-pkill -9 -f "[c]hrome-linux64" 2>/dev/null || true
	-pkill -f "[s]treamlit run app.py" 2>/dev/null || true
	-pkill -9 -f "[m]arp" 2>/dev/null || true
