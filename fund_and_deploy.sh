#!/usr/bin/env bash
set -euo pipefail
trap 'echo "FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
RPC=http://127.0.0.1:8545
ME=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
CELO_ERC20=0x471EcE3750Da237f93B8E339c536989b8978a438
cUSD=0x765DE816845861e75A25fCA122bb6898B8B1282a
cKES=0x456a3D042C0DbD3db53D5489e98dFb038553B0d0
CELO_HOLDER=0xD533Ca259b330c7A88f74E000a3FaEa2d63B7972
cUSD_HOLDER=0xD533Ca259b330c7A88f74E000a3FaEa2d63B7972
cKES_HOLDER=0x61ef8708fc240dc7f9f2c0d81c3124df2fd8829f
AMOUNT=100000000000000000000
GAS=0x3635C9ADC5DEA00000
cast rpc \
  --rpc-url "$RPC" \
  anvil_setBalance "$ME" "$GAS"
TOKENS=("$CELO_ERC20" "$cUSD" "$cKES")
HOLDERS=("$CELO_HOLDER" "$cUSD_HOLDER" "$cKES_HOLDER")
for i in "${!TOKENS[@]}"; do
  TOKEN="${TOKENS[$i]}"
  HOLDER="${HOLDERS[$i]}"
  BAL=$(cast call \
    "$TOKEN" \
    "balanceOf(address)" \
    "$HOLDER" \
    --rpc-url "$RPC")
  export BAL AMOUNT
  SEND=$(python3 - <<'PY'
import os
s=os.environ["BAL"].strip()
amt=int(os.environ["AMOUNT"])
bal=int(s,0)
print(min(bal,amt))
PY
)
  if [ "$SEND" = "0" ]; then
    echo "Holder $HOLDER has zero balance for token $TOKEN" >&2
    exit 1
  fi
  cast rpc \
    --rpc-url "$RPC" \
    anvil_setBalance "$HOLDER" "$GAS"
  cast rpc \
    --rpc-url "$RPC" \
    anvil_impersonateAccount "$HOLDER"
  cast send \
    --from "$HOLDER" \
    --rpc-url "$RPC" \
    "$TOKEN" \
    "transfer(address,uint256)" \
    "$ME" \
    "$SEND" \
    --unlocked
  cast rpc \
    --rpc-url "$RPC" \
    anvil_stopImpersonatingAccount "$HOLDER"
done
echo "Final native CELO balance:"
cast balance "$ME" --rpc-url "$RPC"
echo "Final CELO-ERC20 balance:"
cast call "$CELO_ERC20" "balanceOf(address)" "$ME" --rpc-url "$RPC"
echo "Final cUSD balance:"
cast call "$cUSD" "balanceOf(address)" "$ME" --rpc-url "$RPC"
echo "Final cKES balance:"
cast call "$cKES" "balanceOf(address)" "$ME" --rpc-url "$RPC"
forge script script/Deploy.s.sol --rpc-url "$RPC" --private-key "$PK" --broadcast
