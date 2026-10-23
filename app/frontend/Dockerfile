# nginx-unprivileged runs as UID 101, listens on 8080 and keeps its pid and temp files in /tmp,
# so it works with runAsNonRoot and readOnlyRootFilesystem (with an emptyDir on /tmp)
FROM nginxinc/nginx-unprivileged:1.30-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html/index.html
USER 101
EXPOSE 8080
