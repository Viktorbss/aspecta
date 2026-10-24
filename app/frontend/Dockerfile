# nginx-unprivileged runs as UID 101, listens on 8080 and keeps its pid and temp files in /tmp,
# so it works with runAsNonRoot and readOnlyRootFilesystem (with an emptyDir on /tmp)
FROM nginxinc/nginx-unprivileged:1.30-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html/index.html
# release metadata shown on the page, set by the release workflow; written at build time because the
# root filesystem is read-only at runtime
ARG VERSION=dev
ARG BUILD_TIME=unknown
USER root
RUN printf '{"version":"%s","built_at":"%s"}\n' "$VERSION" "$BUILD_TIME" >/usr/share/nginx/html/version.json
USER 101
EXPOSE 8080
