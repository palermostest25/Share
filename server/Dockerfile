FROM golang:1.26.4-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
COPY *.go ./
COPY web ./web
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o /nasdrive .

FROM scratch
COPY --from=build /nasdrive /nasdrive
USER 568:568
EXPOSE 8080
ENTRYPOINT ["/nasdrive"]
