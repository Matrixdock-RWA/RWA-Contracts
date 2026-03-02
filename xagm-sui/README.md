# XAGm-Sui

XAGm on the Sui blockchain.

| Sui Package   | EVM Contract  |
| ------------- | ------------- |
| mtoken & xagm | MTokenSide    |
| minter        | MTokenMinter  |

---

## 🛠️ Prerequisites

Ensure you have the [Sui CLI](https://docs.sui.io/guides/developer/getting-started/sui-install) installed:

```bash
sui --version
```

---

## ✅ Run Unit Tests

Navigate to a package (e.g., `mtoken`) and run the unit tests:

```bash
cd packages/mtoken
sui move test
```

---

## 📊 Test Coverage

To generate and inspect test coverage reports:

```bash
cd packages/mtoken
sui move test --coverage
sui move coverage summary --test
sui move coverage source --module mtoken
```

Learn more: [Sui Move CLI - Coverage](https://docs.sui.io/references/cli/move#get-test-coverage-for-a-module)

---

## 🎨 Code Formatting

Ensure your code adheres to best practices by formatting it with the [Move Formatter](https://move-book.com/guides/code-quality-checklist.html#code-organization).
