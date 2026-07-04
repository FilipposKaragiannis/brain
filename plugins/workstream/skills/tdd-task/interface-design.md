# Interface Design for Testability

Good interfaces make testing natural:

1. **Accept dependencies, don't create them**

   ```csharp
   // Testable
   Receipt ProcessOrder(Order order, IPaymentGateway gateway) { ... }

   // Hard to test
   Receipt ProcessOrder(Order order)
   {
       var gateway = new StripeGateway();
       // ...
   }
   ```

2. **Return results, don't produce side effects**

   ```csharp
   // Testable
   Discount CalculateDiscount(Cart cart) { ... }

   // Hard to test
   void ApplyDiscount(Cart cart)
   {
       cart.Total -= discount;
   }
   ```

3. **Small surface area**
   - Fewer methods = fewer tests needed
   - Fewer params = simpler test setup
