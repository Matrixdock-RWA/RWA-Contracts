SwapPool use pyth as oracle for XAUM price fetch, using MMT XAUM/USDC pool as a TWAP source for pyth price check.
SwapPool use SwapCap to limit only whilelisted user can swap XAUM token.

## Mainnet related params:

| Param                                | Value                 |
|--------------------------------------|-----------------------|
| XAUM Type                            | 0x9d297676e7a4b771ab023291377b2adfaa4938fb9080b8d12430e4b108b836a9::xaum::XAUM | 
| XAUM price id                        | 0xd7db067954e28f51a96fd50c6d51775094025ced2d60af61ec9803e553471c88              | 
| XAUM priceInfoObject id              | 0x2731a8e3e9bc69b2d6af6f4c032fcd4856c77e2c21f839134d1ebcc3a16e4b1b            |
| USDC Type                            | 0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC   |
| MMT OracleDexPool id (XAUM/USDC MMT) | 0xc5bdc685b8006071938b5cb94103dc873c9946578d717c9b5b67fc264ff941e0                |

## Deployed SwapPool Infos:

| Param             | Value                                                              |
|-------------------|--------------------------------------------------------------------|
| SwapPool Package  | 0xb0af46a60fdf9d291c88e01f0c34c6817bc3449fbf0fd76f7be537b72ed5788d |
| SwapPool State id | 0x623de521b9f1b1a8a0a344a8f0872578483818a40df2ba09672b9dbaab1f9d07                                                                  |
| UpgradeCap id     | 0x3491bfdb06ebe259889aefcf8172930b15fb3c0a897fe5f9ec3c82647d06f2af                                                                  |
