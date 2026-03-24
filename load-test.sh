#!/bin/bash

DOMAIN="xmpp-mongo.wingtrill.com"
POD=$(kubectl get pod -n mim -l app.kubernetes.io/name=mongooseim -o jsonpath='{.items[0].metadata.name}')
MYSQL_POD=$(kubectl get pod -n mim -l app.kubernetes.io/name=mysql -o jsonpath='{.items[0].metadata.name}')
PASSWORD="Test1234"
TOTAL_USERS=500

echo "=== POD: $POD ==="

echo "=== Creating $TOTAL_USERS users ==="
for i in $(seq 1 $TOTAL_USERS); do
  kubectl exec -i $POD -n mim -c mongooseim -- \
    mongooseimctl account registerUser \
    --username "loaduser$i" \
    --domain "$DOMAIN" \
    --password "$PASSWORD" 2>/dev/null
  if [ $((i % 50)) -eq 0 ]; then
    echo "Created $i users..."
  fi
done

echo "=== Sending messages between users ==="
for i in $(seq 1 $TOTAL_USERS); do
  TARGET=$((i % TOTAL_USERS + 1))
  kubectl exec -i $POD -n mim -c mongooseim -- \
    mongooseimctl stanza sendMessage \
    --from "loaduser$i@$DOMAIN" \
    --to "loaduser$TARGET@$DOMAIN" \
    --body "Load test message from user $i to user $TARGET" 2>/dev/null
  if [ $((i % 50)) -eq 0 ]; then
    echo "Sent $i messages..."
  fi
done

echo "=== Done! Checking DB ==="
kubectl exec -i $MYSQL_POD -n mim -- \
  mysql -u mongooseim -pmongooseim mongooseim -e "
SELECT COUNT(*) as total_users FROM users;
SELECT COUNT(*) as archived_messages FROM mam_message;
SELECT COUNT(*) as inbox_conversations FROM inbox;
"
