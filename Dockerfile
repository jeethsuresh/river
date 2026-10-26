# syntax=docker/dockerfile:1
FROM rust:1.96.0-bookworm AS matrix-web-build
RUN rustup target add wasm32-unknown-unknown \
    && cargo install --locked wasm-bindgen-cli --version 0.2.129
WORKDIR /src/client/packages/river_matrix/rust
COPY client/packages/river_matrix/rust/ ./
RUN cargo build --release --locked --target wasm32-unknown-unknown \
    && wasm-bindgen target/wasm32-unknown-unknown/release/river_matrix_core.wasm \
       --target no-modules --no-typescript --out-name river_matrix_core --out-dir /out/pkg

FROM debian:bookworm-slim AS flutter-sdk
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git unzip xz-utils zip libglu1-mesa libglib2.0-0 libfontconfig1 \
    && rm -rf /var/lib/apt/lists/*
ARG FLUTTER_REVISION=abaf9c523780a608bd46686fd5e53740a07077f8
ARG FLUTTER_VERSION=3.47.7
RUN git init /opt/flutter && git -C /opt/flutter remote add origin https://github.com/flutter/flutter.git \
    && git -C /opt/flutter fetch --depth 1 origin "refs/tags/$FLUTTER_VERSION:refs/tags/$FLUTTER_VERSION" \
    && git -C /opt/flutter checkout --detach "$FLUTTER_VERSION" \
    && test "$(git -C /opt/flutter rev-parse HEAD)" = "$FLUTTER_REVISION"
ENV PATH=/opt/flutter/bin:$PATH CI=true
RUN flutter config --no-analytics --enable-web && flutter precache --web
WORKDIR /src/client
COPY client/pubspec.yaml client/pubspec.lock ./
COPY client/packages/river_matrix/pubspec.yaml client/packages/river_matrix/pubspec.lock packages/river_matrix/
RUN flutter pub get --enforce-lockfile
COPY client/ ./
RUN cd packages/river_matrix && flutter pub get --enforce-lockfile \
    && cd cargokit/build_tool && dart pub get --enforce-lockfile

FROM flutter-sdk AS frontend-test
RUN flutter analyze && flutter test

FROM flutter-sdk AS matrix-browser-test
RUN apt-get update && apt-get install -y --no-install-recommends chromium python3 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=matrix-web-build /out/pkg /src/client/web/pkg
COPY scripts/test-matrix-browser.sh /src/scripts/test-matrix-browser.sh
RUN bash /src/scripts/test-matrix-browser.sh

FROM flutter-sdk AS matrix-browser-interop-client
RUN apt-get update && apt-get install -y --no-install-recommends chromium python3 openssl \
    && rm -rf /var/lib/apt/lists/*
COPY --from=matrix-web-build /out/pkg /src/client/web/pkg
RUN flutter build web --release --no-pub --no-web-resources-cdn \
    --target tool/matrix_web_interop.dart --output /opt/river-matrix-browser
COPY scripts/run-matrix-browser-interop.sh /opt/run-matrix-browser-interop.sh
ENV DART_EXECUTABLE=/opt/flutter/bin/cache/dart-sdk/bin/dart
CMD ["bash", "/opt/run-matrix-browser-interop.sh"]

FROM flutter-sdk AS frontend-build
COPY --from=matrix-web-build /out/pkg /src/client/web/pkg
RUN flutter build web --release --no-pub --no-web-resources-cdn

FROM golang:1.25.2-bookworm AS backend-source
WORKDIR /src/backend
COPY backend/ ./
FROM backend-source AS backend-test
RUN go test -race ./... && go vet ./...
FROM backend-source AS backend-build
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/river .
FROM gcr.io/distroless/static-debian12:nonroot AS runtime
LABEL org.opencontainers.image.source=https://github.com/jeethsuresh/river
WORKDIR /app
COPY --from=backend-build /out/river /app/river
COPY --from=frontend-build /src/client/build/web /app/web
ENV ADDR=0.0.0.0:8080 STATIC_DIR=/app/web
USER 10001:10001
EXPOSE 8080
ENTRYPOINT ["/app/river"]
