
#!/usr/bin/env bash
set -euo pipefail

mkdir -p ./code
cd ./code

# Three websites
for name in web-1 web-2 web-3; do
  mkdir -p "$name"

  case "$name" in
    web-1)  content="My web 1" ;;
    web-2)  content="My web 2" ;;
    web-3)  content="My web 3" ;;
  esac

  cat > "$name/Dockerfile" <<EOF
FROM nginx:alpine
RUN printf '${content}\n' > /usr/share/nginx/html/index.html
EXPOSE 80
EOF
done

# Seven APIs
for n in $(seq 1 7); do
  mkdir -p "api-$n"

  cat > "api-$n/Dockerfile" <<EOF
FROM nginx:alpine
RUN mkdir -p /usr/share/nginx/html/api-$n \\
 && printf 'Hello API $n\\n' > /usr/share/nginx/html/api-$n/index.html
EXPOSE 80
EOF
done
