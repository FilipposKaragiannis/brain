# Good and Bad Tests

## Good Tests

**Integration-style**: Test through real interfaces, not mocks of internal parts.

```csharp
// GOOD: Tests observable behavior
[Fact]
public async Task User_can_checkout_with_valid_cart()
{
    var cart = CreateCart();
    cart.Add(product);

    var result = await _checkout.CheckoutAsync(cart, paymentMethod);

    Assert.Equal(CheckoutStatus.Confirmed, result.Status);
}
```

Characteristics:

- Tests behavior users/callers care about
- Uses public API only
- Survives internal refactors
- Describes WHAT, not HOW
- One logical assertion per test

## Bad Tests

**Implementation-detail tests**: Coupled to internal structure.

```csharp
// BAD: Tests implementation details
[Fact]
public async Task Checkout_calls_PaymentService_Process()
{
    var payment = new Mock<IPaymentService>();
    await _checkout.CheckoutAsync(cart, payment.Object);
    payment.Verify(p => p.Process(cart.Total), Times.Once); // asserting on a call, not behavior
}
```

Red flags:

- Mocking internal collaborators
- Testing private methods
- Asserting on call counts/order (`Verify(..., Times.Once)`)
- Test breaks when refactoring without behavior change
- Test name describes HOW not WHAT
- Verifying through external means instead of interface

```csharp
// BAD: Bypasses the interface to verify
[Fact]
public async Task CreateUser_saves_to_database()
{
    await _users.CreateUserAsync(new UserRequest { Name = "Alice" });

    var row = await _db.QuerySingleAsync(
        "SELECT * FROM users WHERE name = @name", new { name = "Alice" });
    Assert.NotNull(row);
}

// GOOD: Verifies through the interface
[Fact]
public async Task CreateUser_makes_user_retrievable()
{
    var user = await _users.CreateUserAsync(new UserRequest { Name = "Alice" });

    var retrieved = await _users.GetUserAsync(user.Id);
    Assert.Equal("Alice", retrieved.Name);
}
```

## Meaningful vs Exhaustive Edge Cases

Cover the edges where behavior genuinely changes. Skip permutations that re-exercise a
path you've already proven — they add maintenance cost and no signal.

```csharp
// MEANINGFUL: each pins a distinct behavior or boundary
[Fact] public Task Rejects_checkout_when_the_cart_is_empty() { ... }            // error path
[Fact] public void Applies_free_shipping_exactly_at_the_threshold() { ... }     // boundary
[Fact] public Task Declines_when_the_gateway_reports_insufficient_funds() { ... } // failure path

// EXHAUSTIVE NOISE: same code path, different data — proving it once is enough
[Fact] public void Total_for_2_items() { ... }
[Fact] public void Total_for_3_items() { ... }
[Fact] public void Total_for_4_items() { ... }
```

When several inputs genuinely exercise the **same** behavior, collapse them into one
data-driven test rather than copy-pasting facts — and only include rows that probe a real
boundary:

```csharp
[Theory]
[InlineData(49.99, false)] // just below the free-shipping threshold
[InlineData(50.00, true)]  // exactly at it
[InlineData(75.00, true)]  // above it
public void Free_shipping_applies_at_or_above_the_threshold(decimal subtotal, bool expectedFree)
{
    var result = ShippingPolicy.For(subtotal);
    Assert.Equal(expectedFree, result.IsFree);
}
```

Ask of each test (or `[InlineData]` row): *if this failed, would it reveal a bug a sibling
wouldn't?* If no, it's noise.

## Keep Test Concerns Out of Core Paths

Code must be testable **by design**, never by editing the core path to accommodate a test.
The implementation should not be able to tell whether it's running under a test.

```csharp
// BAD: production code branches on test state
public ChargeResult Charge(Order order)
{
    if (Environment.GetEnvironmentVariable("ASPNETCORE_ENVIRONMENT") == "Test")
        return ChargeResult.Confirmed(); // test-only hook in a core path
    return _gateway.Charge(order.Total);
}

// GOOD: inject the boundary — the test passes a fake gateway, the core path is untouched
public ChargeResult Charge(Order order, IPaymentGateway gateway)
    => gateway.Charge(order.Total);
```

Red flags that core code has been bent for tests:

- `if (env == "Test")` or `#if DEBUG` test branches in a production path
- Members widened to `public`/`internal` (or `[InternalsVisibleTo]` added) **solely** so a
  test can reach them — that's a signal you're testing internals, not public behavior
- Test-only parameters, flags, or hooks threaded through core logic
- A "test mode" the class switches on internally

When code is hard to test, the fix is the interface (inject the dependency, return the value,
shrink the surface) — not a seam carved into the implementation.
