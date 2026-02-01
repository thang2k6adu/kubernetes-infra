#!/bin/bash

NAMESPACE=$1
SECRET_NAME=$2
CERT_PATH=$3

ENV_FILE=".env"
WHITELIST="secrets.whitelist"
KUSTOMIZATION="kustomization.yaml"

if [ ! -f "$ENV_FILE" ]; then echo ".env not found"; exit 1; fi
if [ ! -f "$WHITELIST" ]; then echo "secrets.whitelist not found"; exit 1; fi
if [ ! -f "$KUSTOMIZATION" ]; then echo "kustomization.yaml not found"; exit 1; fi

CERT_PATH=$(realpath "$CERT_PATH")

grep -v '^#' "$ENV_FILE" | grep -v '^$' > all.env
> secret.env
> config.env

while IFS='=' read -r key value; do
  if grep -qx "$key" "$WHITELIST"; then
    echo "$key=$value" >> secret.env
  else
    echo "$key=$value" >> config.env
  fi
done < all.env

kubectl create configmap app-config \
  --from-env-file=config.env \
  -n "$NAMESPACE" \
  --dry-run=client -o yaml > configmap.yaml

kubectl create secret generic "$SECRET_NAME" \
  --from-env-file=secret.env \
  -n "$NAMESPACE" \
  --dry-run=client -o yaml > secret.yaml

kubeseal --cert "$CERT_PATH" --namespace "$NAMESPACE" --format yaml < secret.yaml > sealed-secret.yaml

rm -f all.env secret.env secret.yaml

# ===== Update kustomization.yaml correctly =====
HAS_RESOURCES=$(grep -n '^resources:' "$KUSTOMIZATION" | cut -d: -f1)

HAS_CONFIG=$(grep -q 'configmap.yaml' "$KUSTOMIZATION" && echo yes || echo no)
HAS_SEALED=$(grep -q 'sealed-secret.yaml' "$KUSTOMIZATION" && echo yes || echo no)

if [ -z "$HAS_RESOURCES" ]; then
  echo "resources:" >> "$KUSTOMIZATION"
  echo "  - configmap.yaml" >> "$KUSTOMIZATION"
  echo "  - sealed-secret.yaml" >> "$KUSTOMIZATION"
else
  LINE=$HAS_RESOURCES

  if [ "$HAS_CONFIG" = "no" ]; then
    sed -i "$((LINE+1))i\  - configmap.yaml" "$KUSTOMIZATION"
    LINE=$((LINE+1))
  fi

  if [ "$HAS_SEALED" = "no" ]; then
    sed -i "$((LINE+1))i\  - sealed-secret.yaml" "$KUSTOMIZATION"
  fi
fi

echo "Done. Generated configmap.yaml and sealed-secret.yaml"
