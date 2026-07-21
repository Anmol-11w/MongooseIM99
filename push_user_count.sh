#!/bin/bash
PUSHGATEWAY="http://10.43.34.9:9091"
MIM_POD=$(kubectl get pod -n mim -l app.kubernetes.io/name=mongooseim -o jsonpath='{.items[0].metadata.name}')

while true; do
  TOTAL=$(kubectl exec -n mim $MIM_POD -- \
    mongooseimctl account countUsers \
    --domain "xmpp-mongo.wingtrill.com" 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin)['data']['account']['countUsers'])")

  echo "mongooseim_registered_users_total $TOTAL" | \
    curl -s --data-binary @- \
    "$PUSHGATEWAY/metrics/job/mongooseim_users"

  echo "$(date): pushed total_users=$TOTAL"
  sleep 30
done
