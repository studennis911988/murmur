check:
	swift run MurmurChecks

app:
	scripts/build-app.sh

install:
	scripts/build-app.sh --install

run: app
	open build/Murmur.app

models:
	scripts/setup-models.sh --use

clean:
	rm -rf .build build

.PHONY: check app install run models clean
