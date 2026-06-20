# When to Mock

Mock at **system boundaries** only:

- External APIs (payment, email, etc.)
- Databases (sometimes - prefer a real test database)
- Time/randomness (`TimeProvider`, `Random`)
- File system (sometimes)

Don't mock:

- Your own classes/services
- Internal collaborators
- Anything you control

## Designing for Mockability

At system boundaries, depend on an **interface** that's easy to substitute — a hand-written fake or a Moq mock.

**1. Use dependency injection**

Pass external dependencies in rather than creating them internally:

```csharp
// Easy to substitute — the test supplies a fake IPaymentClient
Task<ChargeResult> ProcessPaymentAsync(Order order, IPaymentClient paymentClient)
    => paymentClient.ChargeAsync(order.Total);

// Hard to substitute — the dependency is hard-wired
Task<ChargeResult> ProcessPaymentAsync(Order order)
{
    var client = new StripeClient(Environment.GetEnvironmentVariable("STRIPE_KEY"));
    return client.ChargeAsync(order.Total);
}
```

**2. Prefer specific interfaces over one generic gateway**

Declare a method per external operation instead of one generic call with conditional logic:

```csharp
// GOOD: each operation is independently substitutable
public interface IStoreApi
{
    Task<User> GetUserAsync(int id);
    Task<IReadOnlyList<Order>> GetOrdersAsync(int userId);
    Task<Order> CreateOrderAsync(OrderRequest request);
}

// BAD: substituting requires conditional logic inside the fake
public interface IStoreApi
{
    Task<HttpResponseMessage> SendAsync(string endpoint, HttpRequestMessage request);
}
```

The specific-interface approach means:

- Each fake returns one specific shape
- No conditional logic in test setup
- Easier to see which operations a test exercises
- Type safety per operation
