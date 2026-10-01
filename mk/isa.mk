# instruction-stream core (DE1-SoC spec): reference model tests
isa-model-test:
	@python3 $(TEST_DIR)/isa/test_isa_model.py

.PHONY: isa-model-test
