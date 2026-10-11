# The backend in one image: the Go binary, the board page, and pi as the agent command (so a
# committed task runs through OpenRouter's gemini-3.5-flash-lite in the container). Railway builds
# this from the repo root; `docker build -t undercurrent .` does the same locally.
FROM golang:1.26-alpine AS build
WORKDIR /src
COPY backend/go.mod backend/go.sum ./
RUN go mod download
COPY backend/ .
RUN CGO_ENABLED=0 go build -o /undercurrent ./cmd/undercurrent

FROM node:22-slim
RUN npm install -g --ignore-scripts @earendil-works/pi-coding-agent@1.1.0 && npm cache clean --force
WORKDIR /app
COPY --from=build /undercurrent /usr/local/bin/undercurrent
COPY backend/internal-web-ui ./internal-web-ui
COPY backend/elevenlabs ./elevenlabs
ENV AGENT_CMD="pi -p --model openrouter/google/gemini-3.5-flash-lite --no-session -nc --thinking low" \
    AGENT_DIR=/tmp/undercurrent-agent PI_CODING_AGENT_DIR=/tmp/pi PI_SKIP_VERSION_CHECK=1 PI_TELEMETRY=0 PORT=8787
EXPOSE 8787
CMD ["undercurrent", "serve"]
