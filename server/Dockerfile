FROM golang:1.26.4-alpine AS build
ARG VERSION=1.3.0
WORKDIR /src
COPY go.mod go.sum ./
COPY *.go ./
COPY web ./web
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w -X main.version=${VERSION}" -o /nasdrive .

FROM scratch
COPY --from=build /nasdrive /nasdrive
LABEL org.opencontainers.image.source="https://github.com/palermostest25/Share"
USER 568:568
EXPOSE 8080
ENTRYPOINT ["/nasdrive"]
