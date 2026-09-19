# PiliSync 一起看信令服务器（多阶段构建，产出静态二进制）
# 本地构建: docker build -t pilisync-signaling signaling/
# ServerX 部署走 ServerX/pilisync/（compose 以 git 上下文引本目录）

FROM golang:alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/signaling-server .

FROM alpine:3
RUN apk add --no-cache ca-certificates wget
WORKDIR /app
COPY --from=build /out/signaling-server /app/signaling-server
EXPOSE 9901
# 环境变量（可选）：TURN_KEY_ID / TURN_API_TOKEN —— 见 README「TURN」节
ENTRYPOINT ["/app/signaling-server"]
