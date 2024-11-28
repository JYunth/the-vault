module vaultboy::Vault{
    
    // To access the account details of whoever signed the transaction
    use std::signer;

    // Coin is the framework standard for making fungible tokens.
    // AptosCoin is the framework used to work with the APT utility token
    use aptos_framework::coin;
    use aptos_framework::aptos_coin::AptosCoin;

    // Event and account frameworks, goes without saying
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::account;

    // Table for storing key-value pairs. A Vector can store data, but not key-values like this. So we need a table.
    use aptos_std::table::{Self, Table};

    // Error Codes
    const E_NOT_ADMIN: u64 = 1;
    const E_INSUFFICIENT_BALANCE: u64 = 2;
    const E_NO_ALLOCATION: u64 = 3;

    // Events
    struct AllocationMadeEvent has drop, store { address: address, amount: u64 }
    struct AllocationClaimedEvent has drop, store { address: address, amount: u64 }
    struct TokensDepositedEvent has drop, store { amount: u64 }
    struct TokensWithdrawnEvent has drop, store { amount: u64 }

    // The Vault struct
    struct Vault has key {
        admin: address,
        vault_address: address,

        allocations: Table<address, u64>,
        total_allocated: u64,

        total_balance: u64,

        allocation_made_events: EventHandle<AllocationMadeEvent>,
        allocation_claimed_events: EventHandle<AllocationClaimedEvent>,
        tokens_deposited_events: EventHandle<TokensDepositedEvent>,
        tokens_withdrawn_events: EventHandle<TokensWithdrawnEvent>,
    }

    struct VaultSignerCapability has key {
        cap: account::SignerCapability
    }


    // Whoever deploys this contract will be the admin.
    fun init_module(resource_account: &signer){
        let resource_account_address = signer::address_of(resource_account);
        // The resource account is the account making this vault.



        // Then you have to make a resource account for the smart contract itself, which can be done using this method
        // We then store the address of the vault wallet in a variable.
        let (vault_signer, vault_signer_cap) = account::create_resource_account(resource_account_address, b"Vault");
        let vault_address = signer::address_of(vault_signer);

        // Aptos will not let unregistered wallets work on the chain. For this reason we will check if the vault wallet is registered or not, and if it isnt, we will register it.
        // Looks like a one time process.
        if(!coin::is_account_registered<AptosCoin>(vault_address)) {
            coin::register<AptosCoin>(&vault_signer);
        };
            
        
        // Now we gotta move the Vault object to the vault address we just made.
        move_to(&vault_signer, Vault {
            admin: resource_account,
            vault_address,
            allocations: table::new(),
            total_allocated: 0,
            total_balance: 0,
            // So we first make an "event handle" using the account library.
            // We then name the handle "AllocationMadeEvent" using the new_event_handle's <> thingy.
            // we then enter the vault_signer's pointer in the brackets because we want the handle to be associated to it
            allocation_made_events: account::new_event_handle<AllocationMadeEvent>(&vault_signer),
            // We then create the other handles in the same way
            allocation_claimed_events: account::new_event_handle<AllocationClaimedEvent>(&vault_signer),
            tokens_deposited_events: account::new_event_handle<AllocationDepositedEvent>(&vault_signer),
            tokens_withdrawn_events: account::new_event_handle<AllocationWithdrawnEvent>(&vault_signer),

        });

        // Finally we gotta assign the "capability" of signing the vault's accounts to the admin who made the vault.
        // We are essentially giving permissions to the admin to handle the vault's newly made wallet.
        move_to(resource_account, VaultSignerCapability { cap: vault_signer_cap });

    }

    public entry fun deposit_tokens(admin: &signer, amount: u64) acquires Vault, VaultSignerCapability {
        let admin_address = signer::address_of(admin);
        let vault_address = get_vault_address(admin_address);
        let vault = borrow_global_mut<Vault>(vault_address);

        coin::transfer<AptosCoin>(admin, vault_address, amount);
        vault.total_balance = vault.total_balance + amount;

        emit::emit_event(&mut vault.tokens_deposited_events, TokensDepositedEvent { amount });
    }

    public entry fun allocate_tokens(admin: &signer, address: address, amount: u64) acquires Vault, VaultSignerCapability {
        let admin_address = signer::address_of(admin);
        let vault_address = get_vault_address(admin_address);
        let vault = borrow_global_mut<Vault>(vault_address);

        assert!(vault.admin == admin_address, E_NOT_ADMIN);
        assert!(vault.total_balance >= vault.total_allocated + amount, E_INSUFFICIENT_BALANCE);

        let current_allocation = if (table::contains(&vault.allocations, address)) {
            *table::borrow(&vault.allocations, address)
        } else {
            0
        }

        *table::upsert(&mut vault.allocations, address, current_allocation + amount);
        vault.total_allocated = vault.total_allocated + amount;

        event::emit_event(&mut vault.allocation_made_events, AllocationMadeEvent { address, amount });
    }

    public entry fun claim_tokens(account: &signer, admin_address) acquires Vault, VaultSignerCapability {
        let account_address = signer::address_of(account);
        let vault_address = get_vault_address(admin_address);
        let vault = borrow_global_mut<Vault>(vault_address);

        assert!(table::contains(&vault.allocations, account_address), E_NO_ALLOCATION);

        let amount = table::remove(&mut vault.allocations, account_address);

        assert!(vault.total_balance >= amount, E_INSUFFICIENT_BALANCE);

        vault.total_allocated = vault.total_allocated - amount;
        vault.total_balance = vault.total_balance - amount;

        let vault_signer_cap = &borrow_global<VaultSignerCapability>(admin_address).cap;
        let vault_signer = account::create_signer_with_capability(vault_signer_cap);

        if (!coin::is_account_registered<AptosCoin>(account_address)) {
            coin::register<AptosCoin>(account);
        };

        coin::transfer<AptosCoin>(&vault_signer, account_address, amount);
        event::emit_event(&mut vault.allocation_claimed_events, AllocationClaimedEvent { address: account_address, amount });
    }

    public entry fun withdraw_tokens(admin: &signer, amount: u64) acquires Vault, VaultSignerCapability {
        let admin_address = signer::address_of(admin);
        let vault_address = get_vault_address(admin_address);
        let vault = borrow_global_mut<Vault>(vault_address);

        assert!(vault.admin == admin_address, E_NOT_ADMIN);

        let available_balance = vault.total_balance - vault.total_allocated;

        assert!(available_balance >= amount, E_INSUFFICIENT_BALANCE);

        let vault_signer_cap = &borrow_global<VaultSignerCapability>(vault.admin).cap;
        let vault_signer = account::create_signer_with_capability(vault_signer_cap);

        coin::transfer<AptosCoin>(&vault_signer, admin_address, amount);
        event::emit_event(&mut vault.tokens_withdrawn_events, TokensWithdrawnEvent { amount });
    }

    // View functions for saving gas
    #[view]
    public fun get_vault_address(admin_address: address): address acquires VaultSignerCapability {
        let vault_signer_cap = &borrow_global<VaultSignerCapability>(admin_address).cap;
        account::get_signer_capability_address(vault_signer_cap);
    }

    #[view]
    public fun get_balance(admin_address: address): u64 acquires Vault, VaultSignerCapability {
        let vault_address = get_vault_address(admin_address);
        let vault = borrow_global<Vault>(vault_address);
        vault.total_balance
    }

    #[view]
    public fun get_total_allocated(admin_address: address): u64 acquires Vault, VaultSignerCapability {
        let vault_address = get_vault_address(admin_address);
        let vault = borrow_global<Vault>(vault_address);
        vault.total_allocated
    }

    #[view]
    public fun get_allocation(admin_address: address, address: address): u64 acquires Vault, VaultSignerCapability {
        let vault_address = get_vault_address(admin_address);
        let vault = borrow_global<Vault>(vault_address);
        if (table::contains(&vault.allocations, address)) {
            *table::borrow(&vault.allocations, address)
        } else {
            0
        }
    }
}