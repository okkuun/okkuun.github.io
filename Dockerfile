FROM alpine

RUN apk add --no-cache nodejs npm \
    && apk add --no-cache git \
    && npm install -g npm@latest \
    && npm init --yes \
    # Add your favorite rules
    && npm install -g \
            textlint \
            textlint-rule-preset-ja-spacing \
            textlint-rule-no-dropping-the-ra \
            textlint-rule-preset-ja-technical-writing \
            textlint-rule-ja-no-orthographic-variants \
            textlint-rule-no-doubled-joshi \
            textlint-rule-no-start-duplicated-conjunction \
            textlint-rule-no-doubled-conjunctive-particle-ga \
            textlint-rule-ja-no-abusage
