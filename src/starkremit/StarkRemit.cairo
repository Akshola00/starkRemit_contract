#[feature("deprecated-starknet-consts")]
#[starknet::contract]
mod StarkRemit {
    // Import necessary libraries and traits
    use pragma_lib::abi::{IPragmaABIDispatcher, IPragmaABIDispatcherTrait};
    use pragma_lib::types::{DataType, PragmaPricesResponse};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePathEntry,
        StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address, get_contract_address};
    use starkremit_contract::base::errors::{
        ERC20Errors, GroupErrors, KYCErrors, MintBurnErrors, RegistrationErrors, TransferErrors,
    };
    use starkremit_contract::base::events::*;
    use starkremit_contract::base::types::{
        Agent, AgentStatus, KYCLevel, KycLevel, KycStatus, RegistrationRequest, RegistrationStatus,
        SavingsGroup, Transfer as TransferData, TransferHistory, TransferStatus, UserKycData,
        UserProfile,
    };
    use starkremit_contract::interfaces::{IERC20, IStarkRemit};

    // Fixed-point scaler for currency conversions (18 decimals)
    const FIXED_POINT_SCALER: u256 = 1_000_000_000_000_000_000;

    // Event definitions
    #[event]
    #[derive(Copy, Drop, starknet::Event)]
    enum Event {
        Transfer: Transfer, // Standard ERC20 transfer event
        Approval: Approval, // Standard ERC20 approval event
        CurrencyRegistered: CurrencyRegistered, // Event for currency registration
        ExchangeRateUpdated: ExchangeRateUpdated, // Event for exchange rate updates
        TokenConverted: TokenConverted, // Event for token conversions
        UserRegistered: UserRegistered, // Event for user registration
        UserProfileUpdated: UserProfileUpdated, // Event for profile updates
        UserDeactivated: UserDeactivated, // Event for user deactivation
        UserReactivated: UserReactivated, // Event for user reactivation
        KYCLevelUpdated: KYCLevelUpdated, // Event for KYC level updates
        KycStatusUpdated: KycStatusUpdated, // Event for KYC status updates
        KycEnforcementEnabled: KycEnforcementEnabled, // Event for KYC enforcement
        // Transfer Administration Events
        TransferCreated: TransferCreated, // Event for transfer creation
        TransferCancelled: TransferCancelled, // Event for transfer cancellation
        TransferCompleted: TransferCompleted, // Event for transfer completion
        TransferPartialCompleted: TransferPartialCompleted, // Event for partial completion
        TransferExpired: TransferExpired, // Event for transfer expiry
        CashOutRequested: CashOutRequested, // Event for cash-out request
        CashOutCompleted: CashOutCompleted, // Event for cash-out completion
        AgentAssigned: AgentAssigned, // Event for agent assignment
        AgentRegistered: AgentRegistered, // Event for agent registration
        AgentStatusUpdated: AgentStatusUpdated, // Event for agent status updates
        TransferHistoryRecorded: TransferHistoryRecorded, // Event for history recording
        // contribution
        ContributionMade: ContributionMade,
        RoundDisbursed: RoundDisbursed,
        RoundCompleted: RoundCompleted,
        ContributionMissed: ContributionMissed,
        MemberAdded: MemberAdded,
        // Savings Group
        GroupCreated: GroupCreated, // New savings group created
        MemberJoined: MemberJoined, // User joined a savings group
        // Token Supply Events
        Minted: Minted,
        Burned: Burned,
        MinterAdded: MinterAdded,
        MinterRemoved: MinterRemoved,
        MaxSupplyUpdated: MaxSupplyUpdated,
    }


    // Enum for the status of a contribution round
    #[derive(Copy, Drop, Serde, PartialEq, starknet::Store)]
    enum RoundStatus {
        Active,
        Completed,
    }

    // Struct for a contribution round
    #[derive(Copy, Drop, Serde, PartialEq, starknet::Store)]
    struct ContributionRound {
        round_id: u256,
        total_contributions: u256,
        status: RoundStatus,
        deadline: u64,
    }

    // Struct for a member's contribution
    #[derive(Copy, Drop, Serde, PartialEq, starknet::Store)]
    struct MemberContribution {
        member: ContractAddress,
        amount: u256,
        contributed_at: u64,
    }


    // Contract storage definition
    #[storage]
    struct Storage {
        // ERC20 standard storage
        admin: ContractAddress, // Admin with special privileges
        name: felt252, // Token name
        symbol: felt252, // Token symbol
        decimals: u8, // Token decimals (precision)
        total_supply: u256, // Total token supply
        balances: Map<ContractAddress, u256>, // User token balances
        allowances: Map<(ContractAddress, ContractAddress), u256>, // Spending allowances
        // Multi-currency support storage
        currency_balances: Map<(ContractAddress, felt252), u256>, // User balances by currency
        supported_currencies: Map<felt252, bool>, // Registered currencies
        oracle_address: ContractAddress, // Oracle contract address for exchange rates
        // User registration storage
        user_profiles: Map<ContractAddress, UserProfile>, // User profile data
        email_registry: Map<
            felt252, ContractAddress,
        >, // Email hash to address mapping for uniqueness
        phone_registry: Map<
            felt252, ContractAddress,
        >, // Phone hash to address mapping for uniqueness
        registration_status: Map<ContractAddress, RegistrationStatus>, // User registration status
        total_users: u256, // Total number of registered users
        registration_enabled: bool, // Whether registration is currently enabled
        // KYC storage
        kyc_enforcement_enabled: bool,
        user_kyc_data: Map<ContractAddress, UserKycData>,
        // Transaction limits stored per level (0=None, 1=Basic, 2=Enhanced, 3=Premium)
        daily_limits: Map<u8, u256>,
        single_limits: Map<u8, u256>,
        daily_usage: Map<ContractAddress, u256>,
        last_reset: Map<ContractAddress, u64>,
        // Transfer Administration storage
        transfers: Map<u256, TransferData>, // Transfer ID to Transfer mapping
        next_transfer_id: u256, // Counter for generating unique transfer IDs
        user_sent_transfers: Map<
            (ContractAddress, u32), u256,
        >, // User's sent transfers (user, index) -> transfer_id
        user_sent_count: Map<ContractAddress, u32>, // Count of transfers sent by user
        user_received_transfers: Map<
            (ContractAddress, u32), u256,
        >, // User's received transfers (user, index) -> transfer_id
        user_received_count: Map<ContractAddress, u32>, // Count of transfers received by user
        // Agent Management storage
        agents: Map<ContractAddress, Agent>, // Agent address to Agent mapping
        agent_exists: Map<ContractAddress, bool>, // Check if agent exists
        agent_by_region: Map<
            (felt252, u32), ContractAddress,
        >, // Agents by region (region, index) -> agent_address
        agent_region_count: Map<felt252, u32>, // Count of agents by region
        // Transfer History storage
        transfer_history: Map<
            (u256, u32), TransferHistory,
        >, // Transfer history (transfer_id, index) -> history
        transfer_history_count: Map<u256, u32>, // Count of history entries per transfer
        actor_history: Map<
            (ContractAddress, u32), (u256, u32),
        >, // Actor's history (actor, index) -> (transfer_id, history_index)
        actor_history_count: Map<ContractAddress, u32>, // Count of history entries by actor
        action_history: Map<
            (felt252, u32), (u256, u32),
        >, // Action history (action, index) -> (transfer_id, history_index)
        action_history_count: Map<felt252, u32>, // Count of history entries by action
        // Statistics storage
        total_transfers: u256, // Total number of transfers created
        total_completed_transfers: u256, // Total completed transfers
        total_cancelled_transfers: u256, // Total cancelled transfers
        total_expired_transfers: u256, // Total expired transfer
        // contribution storage
        rounds: Map<u256, ContributionRound>,
        member_contributions: Map<(u256, ContractAddress), MemberContribution>,
        rotation_schedule: Map<u256, ContractAddress>,
        round_ids: u256,
        contribution_deadline: u64,
        members: Map<ContractAddress, bool>,
        member_count: u32, //
        member_by_index: Map<u32, ContractAddress>,
        // Savings Group storage
        groups: Map<u64, SavingsGroup>, // Stores all savings groups by ID
        group_members: Map<(u64, ContractAddress), bool>, // True if user is member of given group
        group_count: u64, // Counter used to assign unique group IDs
        // Token Supply Management
        max_supply: u256, // Maximum total supply of the token
        minters: Map<ContractAddress, bool> // Addresses authorized to mint tokens
    }

    // Contract constructor pragma_contract
    // Initializes the token with basic ERC20 fields and multi-currency support
    #[constructor]
    fn constructor(
        ref self: ContractState,
        admin: ContractAddress, // Admin address
        name: felt252, // Token name
        symbol: felt252, // Token symbol
        initial_supply: u256, // Initial token supply
        max_supply: u256, // Maximum token supply
        base_currency: felt252, // Base currency identifier
        oracle_address: ContractAddress // Oracle contract address
    ) {
        // Initialize ERC20 standard fields
        self.admin.write(admin);
        self.name.write(name);
        self.symbol.write(symbol);
        self.decimals.write(18); // Standard 18 decimals for ERC20
        self.total_supply.write(initial_supply);
        self.balances.write(admin, initial_supply);

        // Initialize multi-currency support
        self.supported_currencies.write(base_currency, true);
        self.currency_balances.write((admin, base_currency), initial_supply);
        self.oracle_address.write(oracle_address);

        // Initialize user registration system
        self.total_users.write(0);
        self.registration_enabled.write(true);

        // Initialize KYC with default settings
        self.kyc_enforcement_enabled.write(false);
        self._set_default_transaction_limits();

        // Initialize transfer administration
        self.next_transfer_id.write(1); // Start transfer IDs from 1
        self.total_transfers.write(0);
        self.total_completed_transfers.write(0);
        self.total_cancelled_transfers.write(0);
        self.total_expired_transfers.write(0);

        // Initialize Token Supply Management
        // Max supply must be greater than or equal to initial supply
        assert(max_supply >= initial_supply, MintBurnErrors::MAX_SUPPLY_TOO_LOW);
        self.max_supply.write(max_supply);
        self.minters.write(admin, true); // The deployer/admin is an initial minter

        // Emit transfer event for initial supply
        let zero_address: ContractAddress = 0.try_into().unwrap();
        self.emit(Transfer { from: zero_address, to: admin, value: initial_supply });
    }

    // Implementation of the ERC20 standard interface
    #[abi(embed_v0)]
    impl IStarkRemitTokenImpl of IStarkRemit::IStarkRemitToken<ContractState> {
        // Returns the token name
        fn name(self: @ContractState) -> felt252 {
            self.name.read()
        }

        // Returns the token symbol
        fn symbol(self: @ContractState) -> felt252 {
            self.symbol.read()
        }

        // Returns the number of decimals used for display
        fn decimals(self: @ContractState) -> u8 {
            self.decimals.read()
        }

        // Returns the total token supply
        fn total_supply(self: @ContractState) -> u256 {
            self.total_supply.read()
        }

        // Returns the token balance of a specific account
        fn balance_of(self: @ContractState, account: ContractAddress) -> u256 {
            self.balances.read(account)
        }

        // Returns the amount approved for a spender by an owner
        fn allowance(
            self: @ContractState, owner: ContractAddress, spender: ContractAddress,
        ) -> u256 {
            self.allowances.read((owner, spender))
        }

        // Transfers tokens from caller to recipient
        fn transfer(ref self: ContractState, recipient: ContractAddress, amount: u256) -> bool {
            let caller = get_caller_address();

            // Validate KYC if enforcement is enabled
            if self.kyc_enforcement_enabled.read() {
                self._validate_kyc_and_limits(caller, amount);
                self._validate_kyc_and_limits(recipient, amount);
            }

            let caller_balance = self.balances.read(caller);
            assert(caller_balance >= amount, ERC20Errors::INSUFFICIENT_BALANCE);

            // Update balances
            self.balances.write(caller, caller_balance - amount);
            let recipient_balance = self.balances.read(recipient);
            self.balances.write(recipient, recipient_balance + amount);

            // Record usage for KYC limits
            if self.kyc_enforcement_enabled.read() {
                self._record_daily_usage(caller, amount);
            }

            self.emit(Transfer { from: caller, to: recipient, value: amount });
            true
        }

        // Approves a spender to spend tokens on behalf of the caller
        fn approve(ref self: ContractState, spender: ContractAddress, amount: u256) -> bool {
            let caller = get_caller_address();
            self.allowances.write((caller, spender), amount);
            self.emit(Approval { owner: caller, spender, value: amount });
            true
        }

        // Transfers tokens on behalf of another account if approved
        fn transfer_from(
            ref self: ContractState,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256,
        ) -> bool {
            let caller = get_caller_address();
            let allowance = self.allowances.read((sender, caller));
            assert(allowance >= amount, ERC20Errors::INSUFFICIENT_ALLOWANCE);

            // Validate KYC if enforcement is enabled
            if self.kyc_enforcement_enabled.read() {
                self._validate_kyc_and_limits(sender, amount);
                self._validate_kyc_and_limits(recipient, amount);
            }

            let sender_balance = self.balances.read(sender);
            assert(sender_balance >= amount, ERC20Errors::INSUFFICIENT_BALANCE);

            // Update allowance and balances
            self.allowances.write((sender, caller), allowance - amount);
            self.balances.write(sender, sender_balance - amount);
            let recipient_balance = self.balances.read(recipient);
            self.balances.write(recipient, recipient_balance + amount);

            // Record usage for KYC limits
            if self.kyc_enforcement_enabled.read() {
                self._record_daily_usage(sender, amount);
            }

            self.emit(Transfer { from: sender, to: recipient, value: amount });
            true
        }

        /// Mints new tokens to a specified recipient.
        /// - Caller must be an authorized minter.
        /// - Minting cannot exceed the `max_supply`.
        /// - Recipient cannot be the zero address.
        /// - Amount must be greater than zero.
        fn mint(ref self: ContractState, recipient: ContractAddress, amount: u256) -> bool {
            let caller = get_caller_address();
            assert(self.minters.read(caller), MintBurnErrors::NOT_MINTER);

            let zero_address: ContractAddress = 0.try_into().unwrap();
            assert(recipient != zero_address, MintBurnErrors::MINT_TO_ZERO);
            assert(amount > 0, MintBurnErrors::MINT_ZERO_AMOUNT);

            let current_total_supply = self.total_supply.read();
            let new_total_supply = current_total_supply + amount;
            assert(new_total_supply <= self.max_supply.read(), MintBurnErrors::MAX_SUPPLY_EXCEEDED);

            self.total_supply.write(new_total_supply);
            let recipient_balance = self.balances.read(recipient);
            self.balances.write(recipient, recipient_balance + amount);

            self.emit(Minted { minter: caller, recipient, amount });
            self.emit(Transfer { from: zero_address, to: recipient, value: amount });
            true
        }

        /// Burns (destroys) a specified amount of tokens from the caller's balance.
        /// - Amount must be greater than zero.
        /// - Caller must have sufficient balance.
        fn burn(ref self: ContractState, amount: u256) -> bool {
            let caller = get_caller_address();
            assert(amount > 0, MintBurnErrors::BURN_ZERO_AMOUNT);

            let caller_balance = self.balances.read(caller);
            assert(caller_balance >= amount, MintBurnErrors::INSUFFICIENT_BALANCE_BURN);

            self.balances.write(caller, caller_balance - amount);
            let current_total_supply = self.total_supply.read();
            self.total_supply.write(current_total_supply - amount);

            let zero_address: ContractAddress = 0.try_into().unwrap();
            self.emit(Burned { account: caller, amount });
            self.emit(Transfer { from: caller, to: zero_address, value: amount });
            true
        }

        /// Adds a new authorized minter. Callable only by the contract admin.
        fn add_minter(ref self: ContractState, minter_address: ContractAddress) -> bool {
            let caller = get_caller_address();
            assert(caller == self.admin.read(), ERC20Errors::NotAdmin);
            let zero_address: ContractAddress = 0.try_into().unwrap();
            assert(minter_address != zero_address, MintBurnErrors::INVALID_MINTER_ADDRESS);

            self.minters.write(minter_address, true);
            self.emit(MinterAdded { account: minter_address, added_by: caller });
            true
        }

        /// Removes an authorized minter. Callable only by the contract admin.
        fn remove_minter(ref self: ContractState, minter_address: ContractAddress) -> bool {
            let caller = get_caller_address();
            assert(caller == self.admin.read(), ERC20Errors::NotAdmin);
            let zero_address: ContractAddress = 0.try_into().unwrap();
            assert(minter_address != zero_address, MintBurnErrors::INVALID_MINTER_ADDRESS);
            // Optional: Add logic to prevent removing the last minter or the admin itself without
            // care.
            // For now, allowing removal.

            self.minters.write(minter_address, false);
            self.emit(MinterRemoved { account: minter_address, removed_by: caller });
            true
        }

        /// Checks if an account is an authorized minter.
        fn is_minter(self: @ContractState, account: ContractAddress) -> bool {
            self.minters.read(account)
        }

        /// Sets the maximum total supply of the token. Callable only by the contract admin.
        /// Max supply cannot be set lower than the current total supply.
        fn set_max_supply(ref self: ContractState, new_max_supply: u256) -> bool {
            let caller = get_caller_address();
            assert(caller == self.admin.read(), ERC20Errors::NotAdmin);
            assert(new_max_supply >= self.total_supply.read(), MintBurnErrors::MAX_SUPPLY_TOO_LOW);

            self.max_supply.write(new_max_supply);
            self.emit(MaxSupplyUpdated { new_max_supply, updated_by: caller });
            true
        }

        /// Gets the maximum total supply of the token.
        fn get_max_supply(self: @ContractState) -> u256 {
            self.max_supply.read()
        }
    }

    // Implementation of the StarkRemit interface with KYC functions
    #[abi(embed_v0)]
    impl IStarkRemitImpl of IStarkRemit::IStarkRemit<ContractState> {
        /// Register a new user with the platform
        /// Validates all data and prevents duplicate registrations
        fn register_user(ref self: ContractState, registration_data: RegistrationRequest) -> bool {
            let caller = get_caller_address();
            let zero_address: ContractAddress = 0.try_into().unwrap();

            // Validate caller is not zero address
            assert(caller != zero_address, RegistrationErrors::ZERO_ADDRESS);

            // Check if registration is enabled
            assert(self.registration_enabled.read(), 'Registration disabled');

            // Check if user is already registered
            let current_status = self.registration_status.read(caller);
            match current_status {
                RegistrationStatus::Completed => {
                    assert(false, RegistrationErrors::USER_ALREADY_REGISTERED);
                },
                RegistrationStatus::Suspended => {
                    assert(false, RegistrationErrors::USER_SUSPENDED);
                },
                _ => {} // Allow registration for NotStarted, InProgress, or Failed
            }

            // Validate registration data
            assert(
                self.validate_registration_data(registration_data),
                RegistrationErrors::INCOMPLETE_DATA,
            );

            // Check for duplicate email
            let existing_email_user = self.email_registry.read(registration_data.email_hash);
            assert(existing_email_user == zero_address, RegistrationErrors::EMAIL_ALREADY_EXISTS);

            // Check for duplicate phone
            let existing_phone_user = self.phone_registry.read(registration_data.phone_hash);
            assert(existing_phone_user == zero_address, RegistrationErrors::PHONE_ALREADY_EXISTS);

            // Check if preferred currency is supported
            assert(
                self.supported_currencies.read(registration_data.preferred_currency),
                RegistrationErrors::UNSUPPORTED_CURRENCY,
            );

            // Set registration status to in progress
            self.registration_status.write(caller, RegistrationStatus::InProgress);

            // Create user profile
            let current_timestamp = get_block_timestamp();
            let user_profile = UserProfile {
                address: caller,
                email_hash: registration_data.email_hash,
                phone_hash: registration_data.phone_hash,
                full_name: registration_data.full_name,
                preferred_currency: registration_data.preferred_currency,
                kyc_level: KYCLevel::None,
                registration_timestamp: current_timestamp,
                is_active: true,
                country_code: registration_data.country_code,
            };

            // Store user profile
            self.user_profiles.write(caller, user_profile);

            // Register email and phone for uniqueness
            self.email_registry.write(registration_data.email_hash, caller);
            self.phone_registry.write(registration_data.phone_hash, caller);

            // Update registration status to completed
            self.registration_status.write(caller, RegistrationStatus::Completed);

            // Increment total users
            let current_total = self.total_users.read();
            self.total_users.write(current_total + 1);

            // Emit registration event
            self
                .emit(
                    UserRegistered {
                        user_address: caller,
                        email_hash: registration_data.email_hash,
                        preferred_currency: registration_data.preferred_currency,
                        registration_timestamp: current_timestamp,
                    },
                );

            true
        }

        //mangage user profile
        /// Get the profile of the calling user
        fn get_my_profile(self: @ContractState) -> UserProfile {
            let caller = get_caller_address();
            self.get_user_profile(caller)
        }

        /// Update the calling user's own profile
        fn update_my_profile(ref self: ContractState, updated_profile: UserProfile) -> bool {
            let caller = get_caller_address();
            // Ensure the caller is updating their own profile
            assert(caller == updated_profile.address, 'Unauthorized update');
            self.update_user_profile(updated_profile)
        }

        /// Get user profile by address
        fn get_user_profile(self: @ContractState, user_address: ContractAddress) -> UserProfile {
            let status = self.registration_status.read(user_address);
            match status {
                RegistrationStatus::Completed => {},
                _ => { assert(false, RegistrationErrors::USER_NOT_FOUND); },
            }

            self.user_profiles.read(user_address)
        }

        /// Update user profile information
        /// Only the user themselves can update their profile
        fn update_user_profile(ref self: ContractState, updated_profile: UserProfile) -> bool {
            let caller = get_caller_address();

            // Verify caller is the profile owner
            assert(caller == updated_profile.address, 'Unauthorized profile update');

            // Verify user is registered and active
            let status = self.registration_status.read(caller);
            match status {
                RegistrationStatus::Completed => {},
                _ => { assert(false, RegistrationErrors::USER_NOT_FOUND); },
            }

            let current_profile = self.user_profiles.read(caller);
            assert(current_profile.is_active, RegistrationErrors::USER_INACTIVE);

            // Validate that core immutable fields haven't changed
            assert(updated_profile.address == current_profile.address, 'Cannot change address');
            assert(
                updated_profile.registration_timestamp == current_profile.registration_timestamp,
                'Cannot change timestamp',
            );

            // If email or phone changed, check for duplicates
            if updated_profile.email_hash != current_profile.email_hash {
                let zero_address: ContractAddress = 0.try_into().unwrap();
                let existing_email_user = self.email_registry.read(updated_profile.email_hash);
                assert(
                    existing_email_user == zero_address, RegistrationErrors::EMAIL_ALREADY_EXISTS,
                );

                // Update email registry
                self.email_registry.write(current_profile.email_hash, zero_address);
                self.email_registry.write(updated_profile.email_hash, caller);
            }

            if updated_profile.phone_hash != current_profile.phone_hash {
                let zero_address: ContractAddress = 0.try_into().unwrap();
                let existing_phone_user = self.phone_registry.read(updated_profile.phone_hash);
                assert(
                    existing_phone_user == zero_address, RegistrationErrors::PHONE_ALREADY_EXISTS,
                );

                // Update phone registry
                self.phone_registry.write(current_profile.phone_hash, zero_address);
                self.phone_registry.write(updated_profile.phone_hash, caller);
            }

            // Check if new preferred currency is supported
            assert(
                self.supported_currencies.read(updated_profile.preferred_currency),
                RegistrationErrors::UNSUPPORTED_CURRENCY,
            );

            // Store updated profile
            self.user_profiles.write(caller, updated_profile);

            // Emit update event
            self
                .emit(
                    UserProfileUpdated { user_address: caller, updated_fields: 'profile_updated' },
                );

            true
        }

        /// Check if user is registered
        fn is_user_registered(self: @ContractState, user_address: ContractAddress) -> bool {
            let status = self.registration_status.read(user_address);
            match status {
                RegistrationStatus::Completed => true,
                _ => false,
            }
        }

        /// Get user registration status
        fn get_registration_status(
            self: @ContractState, user_address: ContractAddress,
        ) -> RegistrationStatus {
            self.registration_status.read(user_address)
        }

        /// Update user KYC level (admin only)
        fn update_kyc_level(
            ref self: ContractState, user_address: ContractAddress, kyc_level: KYCLevel,
        ) -> bool {
            let caller = get_caller_address();

            // Verify caller is admin
            assert(caller == self.admin.read(), ERC20Errors::NotAdmin);

            // Verify user is registered
            assert(self.is_user_registered(user_address), RegistrationErrors::USER_NOT_FOUND);

            let mut user_profile = self.user_profiles.read(user_address);
            let old_level = user_profile.kyc_level;

            // Update KYC level
            user_profile.kyc_level = kyc_level;
            self.user_profiles.write(user_address, user_profile);

            // Emit KYC update event
            self
                .emit(
                    KYCLevelUpdated {
                        user_address, old_level, new_level: kyc_level, admin: caller,
                    },
                );

            true
        }

        /// Deactivate user account (admin only)
        fn deactivate_user(ref self: ContractState, user_address: ContractAddress) -> bool {
            let caller = get_caller_address();

            // Verify caller is admin
            assert(caller == self.admin.read(), ERC20Errors::NotAdmin);

            // Verify user is registered
            assert(self.is_user_registered(user_address), RegistrationErrors::USER_NOT_FOUND);

            let mut user_profile = self.user_profiles.read(user_address);
            user_profile.is_active = false;
            self.user_profiles.write(user_address, user_profile);

            // Update registration status
            self.registration_status.write(user_address, RegistrationStatus::Suspended);

            // Emit deactivation event
            self.emit(UserDeactivated { user_address, admin: caller });

            true
        }

        /// Reactivate user account (admin only)
        fn reactivate_user(ref self: ContractState, user_address: ContractAddress) -> bool {
            let caller = get_caller_address();

            // Verify caller is admin
            assert(caller == self.admin.read(), ERC20Errors::NotAdmin);

            // Verify user exists
            let status = self.registration_status.read(user_address);
            match status {
                RegistrationStatus::Suspended => {},
                _ => { assert(false, 'User not suspended'); },
            }

            let mut user_profile = self.user_profiles.read(user_address);
            user_profile.is_active = true;
            self.user_profiles.write(user_address, user_profile);

            // Update registration status
            self.registration_status.write(user_address, RegistrationStatus::Completed);

            // Emit reactivation event
            self.emit(UserReactivated { user_address, admin: caller });

            true
        }

        /// Get total registered users count
        fn get_total_users(self: @ContractState) -> u256 {
            self.total_users.read()
        }

        /// Validate registration data
        fn validate_registration_data(
            self: @ContractState, registration_data: RegistrationRequest,
        ) -> bool {
            // Check that required fields are not empty (0)
            if registration_data.email_hash == 0 {
                return false;
            }

            if registration_data.phone_hash == 0 {
                return false;
            }

            if registration_data.full_name == 0 {
                return false;
            }

            if registration_data.preferred_currency == 0 {
                return false;
            }

            if registration_data.country_code == 0 {
                return false;
            }

            true
        }

        /// Update KYC status for a user (admin only)
        fn update_kyc_status(
            ref self: ContractState,
            user: ContractAddress,
            status: KycStatus,
            level: KycLevel,
            verification_hash: felt252,
            expires_at: u64,
        ) -> bool {
            let caller = get_caller_address();
            assert(caller == self.admin.read(), ERC20Errors::NotAdmin);

            let current_data = self.user_kyc_data.read(user);
            let old_status = current_data.status;
            let old_level = current_data.level;

            let updated_data = UserKycData {
                user,
                level,
                status,
                verification_hash,
                verified_at: get_block_timestamp(),
                expires_at,
            };

            self.user_kyc_data.write(user, updated_data);

            self
                .emit(
                    KycStatusUpdated {
                        user, old_status, new_status: status, old_level, new_level: level,
                    },
                );

            true
        }

        /// Get KYC status for a user
        fn get_kyc_status(self: @ContractState, user: ContractAddress) -> (KycStatus, KycLevel) {
            let kyc_data = self.user_kyc_data.read(user);
            let current_time = get_block_timestamp();

            // Check if KYC has expired
            if kyc_data.expires_at > 0 && current_time > kyc_data.expires_at {
                return (KycStatus::Expired, kyc_data.level);
            }

            (kyc_data.status, kyc_data.level)
        }

        /// Check if user's KYC is valid
        fn is_kyc_valid(self: @ContractState, user: ContractAddress) -> bool {
            let kyc_data = self.user_kyc_data.read(user);
            let current_time = get_block_timestamp();

            match kyc_data.status {
                KycStatus::Approved => {
                    if kyc_data.expires_at > current_time {
                        true
                    } else {
                        false
                    }
                },
                _ => false,
            }
        }

        /// Set KYC enforcement (admin only)
        fn set_kyc_enforcement(ref self: ContractState, enabled: bool) -> bool {
            let caller = get_caller_address();
            assert(caller == self.admin.read(), ERC20Errors::NotAdmin);

            self.kyc_enforcement_enabled.write(enabled);
            self.emit(KycEnforcementEnabled { enabled, updated_by: caller });

            true
        }

        /// Check if KYC enforcement is enabled
        fn is_kyc_enforcement_enabled(self: @ContractState) -> bool {
            self.kyc_enforcement_enabled.read()
        }

        /// Suspend user's KYC (admin only)
        fn suspend_user_kyc(ref self: ContractState, user: ContractAddress) -> bool {
            let caller = get_caller_address();
            assert(caller == self.admin.read(), ERC20Errors::NotAdmin);

            let mut kyc_data = self.user_kyc_data.read(user);
            let old_status = kyc_data.status;

            kyc_data.status = KycStatus::Suspended;
            self.user_kyc_data.write(user, kyc_data);

            self
                .emit(
                    KycStatusUpdated {
                        user,
                        old_status,
                        new_status: KycStatus::Suspended,
                        old_level: kyc_data.level,
                        new_level: kyc_data.level,
                    },
                );

            true
        }

        /// Reinstate user's KYC (admin only)
        fn reinstate_user_kyc(ref self: ContractState, user: ContractAddress) -> bool {
            let caller = get_caller_address();
            assert(caller == self.admin.read(), ERC20Errors::NotAdmin);

            let mut kyc_data = self.user_kyc_data.read(user);
            let old_status = kyc_data.status;

            // Only allow reinstatement from suspended status
            assert(old_status == KycStatus::Suspended, KYCErrors::INVALID_KYC_STATUS);

            kyc_data.status = KycStatus::Approved;
            self.user_kyc_data.write(user, kyc_data);

            self
                .emit(
                    KycStatusUpdated {
                        user,
                        old_status,
                        new_status: KycStatus::Approved,
                        old_level: kyc_data.level,
                        new_level: kyc_data.level,
                    },
                );

            true
        }


        // Transfer Administration Functions
        /// Create a new transfer
        fn create_transfer(
            ref self: ContractState,
            recipient: ContractAddress,
            amount: u256,
            currency: felt252,
            expires_at: u64,
            metadata: felt252,
        ) -> u256 {
            let caller = get_caller_address();
            let current_time = get_block_timestamp();
            let zero_address: ContractAddress = 0.try_into().unwrap();

            // Validate inputs
            assert(recipient != zero_address, TransferErrors::INVALID_TRANSFER_AMOUNT);
            assert(amount > 0, TransferErrors::INVALID_TRANSFER_AMOUNT);
            assert(expires_at > current_time, TransferErrors::INVALID_EXPIRY_TIME);
            assert(self.supported_currencies.read(currency), TransferErrors::UNSUPPORTED_CURRENCY);

            // Validate KYC if enforcement is enabled
            if self.kyc_enforcement_enabled.read() {
                self._validate_kyc_and_limits(caller, amount);
                self._validate_kyc_and_limits(recipient, amount);
            }

            // Check sender has sufficient balance
            let sender_balance = self.currency_balances.read((caller, currency));
            assert(sender_balance >= amount, ERC20Errors::INSUFFICIENT_BALANCE);

            // Generate transfer ID
            let transfer_id = self.next_transfer_id.read();
            self.next_transfer_id.write(transfer_id + 1);

            // Create transfer
            let transfer = TransferData {
                transfer_id,
                sender: caller,
                recipient,
                amount,
                currency,
                status: TransferStatus::Pending,
                created_at: current_time,
                updated_at: current_time,
                expires_at,
                assigned_agent: zero_address,
                partial_amount: 0,
                metadata,
            };

            // Store transfer
            self.transfers.write(transfer_id, transfer);

            // Update user indices
            let sender_count = self.user_sent_count.read(caller);
            self.user_sent_transfers.write((caller, sender_count), transfer_id);
            self.user_sent_count.write(caller, sender_count + 1);

            let recipient_count = self.user_received_count.read(recipient);
            self.user_received_transfers.write((recipient, recipient_count), transfer_id);
            self.user_received_count.write(recipient, recipient_count + 1);

            // Update statistics
            let total = self.total_transfers.read();
            self.total_transfers.write(total + 1);

            // Record history
            self
                ._record_transfer_history(
                    transfer_id,
                    'created',
                    caller,
                    TransferStatus::Pending,
                    TransferStatus::Pending,
                    'Transfer created',
                );

            // Reserve funds
            self.currency_balances.write((caller, currency), sender_balance - amount);

            // Emit event
            self
                .emit(
                    TransferCreated {
                        transfer_id, sender: caller, recipient, amount, currency, expires_at,
                    },
                );

            transfer_id
        }

        /// Cancel an existing transfer
        fn cancel_transfer(ref self: ContractState, transfer_id: u256) -> bool {
            let caller = get_caller_address();
            let current_time = get_block_timestamp();

            // Get transfer
            let mut transfer = self.transfers.read(transfer_id);
            assert(transfer.transfer_id != 0, TransferErrors::TRANSFER_NOT_FOUND);

            // Check authorization (sender, recipient, or admin can cancel)
            let is_admin = caller == self.admin.read();
            let is_sender = caller == transfer.sender;
            let is_recipient = caller == transfer.recipient;
            assert(is_admin || is_sender || is_recipient, TransferErrors::UNAUTHORIZED_TRANSFER_OP);

            // Check if transfer can be cancelled
            match transfer.status {
                TransferStatus::Completed => assert(
                    false, TransferErrors::TRANSFER_ALREADY_COMPLETED,
                ),
                TransferStatus::Cancelled => assert(
                    false, TransferErrors::TRANSFER_ALREADY_CANCELLED,
                ),
                TransferStatus::Expired => assert(false, TransferErrors::TRANSFER_EXPIRED),
                _ => {} // Can cancel pending, partial, or cash-out requested transfers
            }

            let old_status = transfer.status;

            // Update transfer status
            transfer.status = TransferStatus::Cancelled;
            transfer.updated_at = current_time;
            self.transfers.write(transfer_id, transfer);

            // Refund sender
            let sender_balance = self.currency_balances.read((transfer.sender, transfer.currency));
            let refund_amount = transfer.amount - transfer.partial_amount;
            self
                .currency_balances
                .write((transfer.sender, transfer.currency), sender_balance + refund_amount);

            // Update statistics
            let cancelled_count = self.total_cancelled_transfers.read();
            self.total_cancelled_transfers.write(cancelled_count + 1);

            // Record history
            self
                ._record_transfer_history(
                    transfer_id,
                    'cancelled',
                    caller,
                    old_status,
                    TransferStatus::Cancelled,
                    'Transfer cancelled',
                );

            // Emit event
            self
                .emit(
                    TransferCancelled {
                        transfer_id,
                        cancelled_by: caller,
                        timestamp: current_time,
                        reason: 'user_cancelled',
                    },
                );

            true
        }

        /// Complete a transfer (mark as completed)
        fn complete_transfer(ref self: ContractState, transfer_id: u256) -> bool {
            let caller = get_caller_address();
            let current_time = get_block_timestamp();

            // Get transfer
            let mut transfer = self.transfers.read(transfer_id);
            assert(transfer.transfer_id != 0, TransferErrors::TRANSFER_NOT_FOUND);

            // Check authorization (recipient, assigned agent, or admin can complete)
            let is_admin = caller == self.admin.read();
            let is_recipient = caller == transfer.recipient;
            let is_assigned_agent = transfer.assigned_agent != 0.try_into().unwrap()
                && caller == transfer.assigned_agent;
            assert(
                is_admin || is_recipient || is_assigned_agent,
                TransferErrors::UNAUTHORIZED_TRANSFER_OP,
            );

            // Check status
            match transfer.status {
                TransferStatus::Completed => assert(
                    false, TransferErrors::TRANSFER_ALREADY_COMPLETED,
                ),
                TransferStatus::Cancelled => assert(
                    false, TransferErrors::TRANSFER_ALREADY_CANCELLED,
                ),
                TransferStatus::Expired => assert(false, TransferErrors::TRANSFER_EXPIRED),
                _ => {} // Can complete pending, partial, or cash-out requested transfers
            }

            let old_status = transfer.status;
            let remaining_amount = transfer.amount - transfer.partial_amount;

            // Update transfer status
            transfer.status = TransferStatus::Completed;
            transfer.updated_at = current_time;
            transfer.partial_amount = transfer.amount;
            self.transfers.write(transfer_id, transfer);

            // Transfer remaining funds to recipient
            if remaining_amount > 0 {
                let recipient_balance = self
                    .currency_balances
                    .read((transfer.recipient, transfer.currency));
                self
                    .currency_balances
                    .write(
                        (transfer.recipient, transfer.currency),
                        recipient_balance + remaining_amount,
                    );
            }

            // Update statistics
            let completed_count = self.total_completed_transfers.read();
            self.total_completed_transfers.write(completed_count + 1);

            // Record history
            self
                ._record_transfer_history(
                    transfer_id,
                    'completed',
                    caller,
                    old_status,
                    TransferStatus::Completed,
                    'Transfer completed',
                );

            // Emit event
            self
                .emit(
                    TransferCompleted {
                        transfer_id, completed_by: caller, timestamp: current_time,
                    },
                );

            true
        }

        /// Partially complete a transfer
        fn partial_complete_transfer(
            ref self: ContractState, transfer_id: u256, partial_amount: u256,
        ) -> bool {
            let caller = get_caller_address();
            let current_time = get_block_timestamp();

            // Get transfer
            let mut transfer = self.transfers.read(transfer_id);
            assert(transfer.transfer_id != 0, TransferErrors::TRANSFER_NOT_FOUND);

            // Check authorization
            let is_admin = caller == self.admin.read();
            let is_recipient = caller == transfer.recipient;
            let is_assigned_agent = transfer.assigned_agent != 0.try_into().unwrap()
                && caller == transfer.assigned_agent;
            assert(
                is_admin || is_recipient || is_assigned_agent,
                TransferErrors::UNAUTHORIZED_TRANSFER_OP,
            );

            // Validate partial amount
            assert(partial_amount > 0, TransferErrors::INVALID_TRANSFER_AMOUNT);
            assert(
                transfer.partial_amount + partial_amount <= transfer.amount,
                TransferErrors::PARTIAL_AMOUNT_EXCEEDS,
            );

            // Check status
            match transfer.status {
                TransferStatus::Completed => assert(
                    false, TransferErrors::TRANSFER_ALREADY_COMPLETED,
                ),
                TransferStatus::Cancelled => assert(
                    false, TransferErrors::TRANSFER_ALREADY_CANCELLED,
                ),
                TransferStatus::Expired => assert(false, TransferErrors::TRANSFER_EXPIRED),
                _ => {} // Can partially complete pending or partial transfers
            }

            let old_status = transfer.status;

            // Update transfer
            transfer.partial_amount += partial_amount;
            transfer.updated_at = current_time;

            // Update status to partial if not already
            if transfer.status == TransferStatus::Pending {
                transfer.status = TransferStatus::PartialComplete;
            }

            // Check if now fully completed
            if transfer.partial_amount == transfer.amount {
                transfer.status = TransferStatus::Completed;
            }

            self.transfers.write(transfer_id, transfer);

            // Transfer partial funds to recipient
            let recipient_balance = self
                .currency_balances
                .read((transfer.recipient, transfer.currency));
            self
                .currency_balances
                .write((transfer.recipient, transfer.currency), recipient_balance + partial_amount);

            // Record history
            let action = if transfer.status == TransferStatus::Completed {
                'completed'
            } else {
                'partial_completed'
            };
            self
                ._record_transfer_history(
                    transfer_id,
                    action,
                    caller,
                    old_status,
                    transfer.status,
                    'Transfer partially completed',
                );

            // Emit event
            self
                .emit(
                    TransferPartialCompleted {
                        transfer_id,
                        partial_amount,
                        total_amount: transfer.amount,
                        timestamp: current_time,
                    },
                );

            true
        }

        /// Request cash-out for a transfer
        fn request_cash_out(ref self: ContractState, transfer_id: u256) -> bool {
            let caller = get_caller_address();
            let current_time = get_block_timestamp();

            // Get transfer
            let mut transfer = self.transfers.read(transfer_id);
            assert(transfer.transfer_id != 0, TransferErrors::TRANSFER_NOT_FOUND);

            // Check authorization (only recipient can request cash-out)
            assert(caller == transfer.recipient, TransferErrors::UNAUTHORIZED_TRANSFER_OP);

            // Check status (can only request cash-out for pending or partial transfers)
            match transfer.status {
                TransferStatus::Pending | TransferStatus::PartialComplete => {},
                _ => assert(false, TransferErrors::INVALID_TRANSFER_STATUS),
            }

            let old_status = transfer.status;

            // Update status
            transfer.status = TransferStatus::CashOutRequested;
            transfer.updated_at = current_time;
            self.transfers.write(transfer_id, transfer);

            // Record history
            self
                ._record_transfer_history(
                    transfer_id,
                    'cash_out_requested',
                    caller,
                    old_status,
                    TransferStatus::CashOutRequested,
                    'Cash-out requested',
                );

            // Emit event
            self
                .emit(
                    CashOutRequested { transfer_id, requested_by: caller, timestamp: current_time },
                );

            true
        }

        /// Complete cash-out (agent only)
        fn complete_cash_out(ref self: ContractState, transfer_id: u256) -> bool {
            let caller = get_caller_address();
            let current_time = get_block_timestamp();

            // Get transfer
            let mut transfer = self.transfers.read(transfer_id);
            assert(transfer.transfer_id != 0, TransferErrors::TRANSFER_NOT_FOUND);

            // Check if caller is authorized agent
            assert(
                self.is_agent_authorized(caller, transfer_id), TransferErrors::AGENT_NOT_AUTHORIZED,
            );

            // Check status
            assert(
                transfer.status == TransferStatus::CashOutRequested,
                TransferErrors::INVALID_TRANSFER_STATUS,
            );

            let old_status = transfer.status;

            // Update status
            transfer.status = TransferStatus::CashOutCompleted;
            transfer.updated_at = current_time;
            self.transfers.write(transfer_id, transfer);

            // Record history
            self
                ._record_transfer_history(
                    transfer_id,
                    'cash_out_completed',
                    caller,
                    old_status,
                    TransferStatus::CashOutCompleted,
                    'Cash-out completed',
                );

            // Emit event
            self.emit(CashOutCompleted { transfer_id, agent: caller, timestamp: current_time });

            true
        }

        /// Get transfer details
        fn get_transfer(self: @ContractState, transfer_id: u256) -> TransferData {
            let transfer = self.transfers.read(transfer_id);
            assert(transfer.transfer_id != 0, TransferErrors::TRANSFER_NOT_FOUND);
            transfer
        }

        /// Get transfers by sender
        fn get_transfers_by_sender(
            self: @ContractState, sender: ContractAddress, limit: u32, offset: u32,
        ) -> Array<TransferData> {
            let mut transfers = ArrayTrait::new();
            let total_count = self.user_sent_count.read(sender);

            let mut i = offset;
            let mut count = 0;

            while i < total_count && count < limit {
                let transfer_id = self.user_sent_transfers.read((sender, i));
                let transfer = self.transfers.read(transfer_id);
                transfers.append(transfer);
                count += 1;
                i += 1;
            }

            transfers
        }

        /// Get transfers by recipient
        fn get_transfers_by_recipient(
            self: @ContractState, recipient: ContractAddress, limit: u32, offset: u32,
        ) -> Array<TransferData> {
            let mut transfers = ArrayTrait::new();
            let total_count = self.user_received_count.read(recipient);

            let mut i = offset;
            let mut count = 0;

            while i < total_count && count < limit {
                let transfer_id = self.user_received_transfers.read((recipient, i));
                let transfer = self.transfers.read(transfer_id);
                transfers.append(transfer);
                count += 1;
                i += 1;
            }

            transfers
        }

        /// Get transfers by status
        fn get_transfers_by_status(
            self: @ContractState, status: TransferStatus, limit: u32, offset: u32,
        ) -> Array<TransferData> {
            let mut transfers = ArrayTrait::new();
            let total_transfers = self.total_transfers.read();

            let mut i = 1; // Transfer IDs start from 1
            let mut count = 0;
            let mut found = 0;

            while i <= total_transfers && count < limit {
                let transfer = self.transfers.read(i);
                if transfer.transfer_id != 0 && transfer.status == status {
                    if found >= offset {
                        transfers.append(transfer);
                        count += 1;
                    }
                    found += 1;
                }
                i += 1;
            }

            transfers
        }

        /// Get expired transfers
        fn get_expired_transfers(
            self: @ContractState, limit: u32, offset: u32,
        ) -> Array<TransferData> {
            let mut transfers = ArrayTrait::new();
            let current_time = get_block_timestamp();
            let total_transfers = self.total_transfers.read();

            let mut i = 1; // Transfer IDs start from 1
            let mut count = 0;
            let mut found = 0;

            while i <= total_transfers && count < limit {
                let transfer = self.transfers.read(i);
                if transfer.transfer_id != 0
                    && transfer.expires_at <= current_time
                    && transfer.status == TransferStatus::Pending {
                    if found >= offset {
                        transfers.append(transfer);
                        count += 1;
                    }
                    found += 1;
                }
                i += 1;
            }

            transfers
        }

        /// Process expired transfers (admin only)
        fn process_expired_transfers(ref self: ContractState, limit: u32) -> u32 {
            let caller = get_caller_address();
            assert(caller == self.admin.read(), ERC20Errors::NotAdmin);

            let current_time = get_block_timestamp();
            let total_transfers = self.total_transfers.read();

            let mut processed = 0;
            let mut i = 1; // Transfer IDs start from 1

            while i <= total_transfers && processed < limit {
                let mut transfer = self.transfers.read(i);

                if transfer.transfer_id != 0
                    && transfer.expires_at <= current_time
                    && transfer.status == TransferStatus::Pending {
                    // Mark as expired
                    transfer.status = TransferStatus::Expired;
                    transfer.updated_at = current_time;
                    self.transfers.write(i, transfer);

                    // Refund sender
                    let sender_balance = self
                        .currency_balances
                        .read((transfer.sender, transfer.currency));
                    let refund_amount = transfer.amount - transfer.partial_amount;
                    self
                        .currency_balances
                        .write(
                            (transfer.sender, transfer.currency), sender_balance + refund_amount,
                        );

                    // Update statistics
                    let expired_count = self.total_expired_transfers.read();
                    self.total_expired_transfers.write(expired_count + 1);

                    // Record history
                    self
                        ._record_transfer_history(
                            i,
                            'expired',
                            caller,
                            TransferStatus::Pending,
                            TransferStatus::Expired,
                            'Transfer expired',
                        );

                    // Emit event
                    self.emit(TransferExpired { transfer_id: i, timestamp: current_time });

                    processed += 1;
                }

                i += 1;
            }

            processed
        }

        /// Assign agent to transfer (admin only)
        fn assign_agent_to_transfer(
            ref self: ContractState, transfer_id: u256, agent: ContractAddress,
        ) -> bool {
            let caller = get_caller_address();
            let current_time = get_block_timestamp();
            assert(caller == self.admin.read(), ERC20Errors::NotAdmin);

            // Validate agent exists and is active
            assert(self.agent_exists.read(agent), TransferErrors::AGENT_NOT_FOUND);
            let agent_data = self.agents.read(agent);
            assert(agent_data.status == AgentStatus::Active, TransferErrors::AGENT_NOT_ACTIVE);

            // Get transfer
            let mut transfer = self.transfers.read(transfer_id);
            assert(transfer.transfer_id != 0, TransferErrors::TRANSFER_NOT_FOUND);

            // Update transfer
            transfer.assigned_agent = agent;
            transfer.updated_at = current_time;
            self.transfers.write(transfer_id, transfer);

            // Record history
            self
                ._record_transfer_history(
                    transfer_id,
                    'agent_assigned',
                    caller,
                    transfer.status,
                    transfer.status,
                    'Agent assigned',
                );

            // Emit event
            self
                .emit(
                    AgentAssigned {
                        transfer_id, agent, assigned_by: caller, timestamp: current_time,
                    },
                );

            true
        }

        // Agent Management Functions
        /// Register a new agent (admin only)
        fn register_agent(
            ref self: ContractState,
            agent_address: ContractAddress,
            name: felt252,
            primary_currency: felt252,
            secondary_currency: felt252,
            primary_region: felt252,
            secondary_region: felt252,
            commission_rate: u256,
        ) -> bool {
            let caller = get_caller_address();
            let current_time = get_block_timestamp();
            assert(caller == self.admin.read(), ERC20Errors::NotAdmin);

            // Check if agent already exists
            assert(!self.agent_exists.read(agent_address), TransferErrors::AGENT_ALREADY_EXISTS);

            // Create agent
            let agent = Agent {
                agent_address,
                name,
                status: AgentStatus::Active,
                primary_currency,
                secondary_currency,
                primary_region,
                secondary_region,
                commission_rate,
                completed_transactions: 0,
                total_volume: 0,
                registered_at: current_time,
                last_active: current_time,
                rating: 1000 // Default rating
            };

            // Store agent
            self.agents.write(agent_address, agent);
            self.agent_exists.write(agent_address, true);

            // Update region indices for primary region
            if primary_region != 0 {
                let region_count = self.agent_region_count.read(primary_region);
                self.agent_by_region.write((primary_region, region_count), agent_address);
                self.agent_region_count.write(primary_region, region_count + 1);
            }

            // Update region indices for secondary region if provided
            if secondary_region != 0 {
                let region_count = self.agent_region_count.read(secondary_region);
                self.agent_by_region.write((secondary_region, region_count), agent_address);
                self.agent_region_count.write(secondary_region, region_count + 1);
            }

            // Emit event
            self
                .emit(
                    AgentRegistered {
                        agent_address,
                        name,
                        commission_rate,
                        registered_by: caller,
                        timestamp: current_time,
                    },
                );

            true
        }

        /// Update agent status (admin only)
        fn update_agent_status(
            ref self: ContractState, agent_address: ContractAddress, status: AgentStatus,
        ) -> bool {
            let caller = get_caller_address();
            let current_time = get_block_timestamp();
            assert(caller == self.admin.read(), ERC20Errors::NotAdmin);

            // Check if agent exists
            assert(self.agent_exists.read(agent_address), TransferErrors::AGENT_NOT_FOUND);

            let mut agent = self.agents.read(agent_address);
            let old_status = agent.status;

            // Update status
            agent.status = status;
            agent.last_active = current_time;
            self.agents.write(agent_address, agent);

            // Emit event
            self
                .emit(
                    AgentStatusUpdated {
                        agent: agent_address,
                        old_status,
                        new_status: status,
                        updated_by: caller,
                        timestamp: current_time,
                    },
                );

            true
        }

        /// Get agent details
        fn get_agent(self: @ContractState, agent_address: ContractAddress) -> Agent {
            assert(self.agent_exists.read(agent_address), TransferErrors::AGENT_NOT_FOUND);
            self.agents.read(agent_address)
        }

        /// Get agents by status
        fn get_agents_by_status(
            self: @ContractState, status: AgentStatus, limit: u32, offset: u32,
        ) -> Array<Agent> {
            let mut agents = ArrayTrait::new();
            // Since we don't have a comprehensive agent list, we'll need to iterate through regions
            // This is a simplified implementation - in production you might want a better indexing
            // system
            let mut _count = 0;
            let mut _found = 0;

            // For now, return empty array as we don't have a comprehensive agent index
            // In a production system, you'd want to maintain a separate agent index
            agents
        }

        /// Get agents by region
        fn get_agents_by_region(
            self: @ContractState, region: felt252, limit: u32, offset: u32,
        ) -> Array<Agent> {
            let mut agents = ArrayTrait::new();
            let total_count = self.agent_region_count.read(region);

            let mut i = offset;
            let mut count = 0;

            while i < total_count && count < limit {
                let agent_address = self.agent_by_region.read((region, i));
                let agent = self.agents.read(agent_address);
                agents.append(agent);
                count += 1;
                i += 1;
            }

            agents
        }

        /// Check if agent is authorized for transfer
        fn is_agent_authorized(
            self: @ContractState, agent: ContractAddress, transfer_id: u256,
        ) -> bool {
            // Check if agent exists and is active
            if !self.agent_exists.read(agent) {
                return false;
            }

            let agent_data = self.agents.read(agent);
            if agent_data.status != AgentStatus::Active {
                return false;
            }

            // Get transfer to check if agent is assigned
            let transfer = self.transfers.read(transfer_id);
            if transfer.transfer_id == 0 {
                return false;
            }

            // Agent must be assigned to this transfer
            agent == transfer.assigned_agent
        }

        // Transfer History Functions
        /// Get transfer history
        fn get_transfer_history(
            self: @ContractState, transfer_id: u256, limit: u32, offset: u32,
        ) -> Array<TransferHistory> {
            let mut history = ArrayTrait::new();
            let total_count = self.transfer_history_count.read(transfer_id);

            let mut i = offset;
            let mut count = 0;

            while i < total_count && count < limit {
                let history_entry = self.transfer_history.read((transfer_id, i));
                history.append(history_entry);
                count += 1;
                i += 1;
            }

            history
        }

        /// Search transfer history by actor
        fn search_history_by_actor(
            self: @ContractState, actor: ContractAddress, limit: u32, offset: u32,
        ) -> Array<TransferHistory> {
            let mut history = ArrayTrait::new();
            let total_count = self.actor_history_count.read(actor);

            let mut i = offset;
            let mut count = 0;

            while i < total_count && count < limit {
                let (transfer_id, history_index) = self.actor_history.read((actor, i));
                let history_entry = self.transfer_history.read((transfer_id, history_index));
                history.append(history_entry);
                count += 1;
                i += 1;
            }

            history
        }

        /// Search transfer history by action
        fn search_history_by_action(
            self: @ContractState, action: felt252, limit: u32, offset: u32,
        ) -> Array<TransferHistory> {
            let mut history = ArrayTrait::new();
            let total_count = self.action_history_count.read(action);

            let mut i = offset;
            let mut count = 0;

            while i < total_count && count < limit {
                let (transfer_id, history_index) = self.action_history.read((action, i));
                let history_entry = self.transfer_history.read((transfer_id, history_index));
                history.append(history_entry);
                count += 1;
                i += 1;
            }

            history
        }

        /// Get transfer statistics
        fn get_transfer_statistics(self: @ContractState) -> (u256, u256, u256, u256) {
            (
                self.total_transfers.read(),
                self.total_completed_transfers.read(),
                self.total_cancelled_transfers.read(),
                self.total_expired_transfers.read(),
            )
        }

        /// Get agent statistics
        fn get_agent_statistics(
            self: @ContractState, agent: ContractAddress,
        ) -> (u256, u256, u256) {
            assert(self.agent_exists.read(agent), TransferErrors::AGENT_NOT_FOUND);
            let agent_data = self.agents.read(agent);
            (agent_data.completed_transactions, agent_data.total_volume, agent_data.rating)
        }

        //contribution management

        fn contribute_round(ref self: ContractState, round_id: u256, amount: u256) {
            let caller = get_caller_address();
            assert(self.is_member(caller), 'Caller is not a member');

            let mut round = self.rounds.read(round_id);
            assert(round.status == RoundStatus::Active, 'Round is not active');
            assert(get_block_timestamp() <= round.deadline, 'Contribution deadline passed');

            let contribution = MemberContribution {
                member: caller, amount, contributed_at: get_block_timestamp(),
            };
            let contract_address = get_contract_address();

            self.member_contributions.write((round_id, caller), contribution);
            round.total_contributions += amount;

            self.rounds.write(round_id, round);

            self.transfer_from(caller, contract_address, amount);

            self.emit(ContributionMade { round_id, member: caller, amount });
        }

        fn disburse_round_contribution(ref self: ContractState, round_id: u256) {
            let round = self.rounds.read(round_id);
            assert(round.status == RoundStatus::Completed, 'Round is not completed');

            let recipient = self.rotation_schedule.read(round_id);
            let amount = round.total_contributions;
            let contract_address = get_contract_address();
            self.transfer_from(contract_address, recipient, amount);

            self.emit(RoundDisbursed { round_id, amount, recipient });
        }


        fn complete_round(ref self: ContractState, round_id: u256) {
            let mut round = self.rounds.read(round_id);
            assert(round.status == RoundStatus::Active, 'Round is not active');
            assert(get_block_timestamp() > round.deadline, 'Deadline not passed');

            round.status = RoundStatus::Completed;
            self.rounds.write(round_id, round);

            self.emit(RoundCompleted { round_id });
        }

        fn is_member(self: @ContractState, address: ContractAddress) -> bool {
            self.members.read(address)
        }


        fn check_missed_contributions(ref self: ContractState, round_id: u256) {
            let round = self.rounds.read(round_id);
            let members = self.get_all_members();

            for member in members {
                let contribution = self.member_contributions.read((round_id, member));
                if contribution.contributed_at == 0 {
                    self.emit(ContributionMissed { round_id, member });
                }
            }
        }


        fn get_all_members(self: @ContractState) -> Array<ContractAddress> {
            let mut result = ArrayTrait::new();
            let count = self.member_count.read();

            let mut i: u32 = 0;
            loop {
                if i >= count {
                    break;
                }

                let member = self.member_by_index.read(i);
                result.append(member);

                i += 1;
            }

            result
        }


        fn add_round_to_schedule(
            ref self: ContractState, recipient: ContractAddress, deadline: u64,
        ) {
            let round_id = self.round_ids.read();
            let round = ContributionRound {
                round_id, total_contributions: 0, status: RoundStatus::Active, deadline,
            };

            self.rounds.write(round_id, round);
            self.rotation_schedule.write(round_id, recipient);
            self.round_ids.write(round_id + 1);
        }

        fn add_member(ref self: ContractState, address: ContractAddress) {
            let caller = get_caller_address();
            assert(caller == self.admin.read(), 'Only admin can add members');
            assert(!self.members.read(address), 'Already a member');

            let count = self.member_count.read();
            self.members.write(address, true);
            self.member_by_index.write(count, address);
            self.member_count.write(count + 1);
            self.emit(MemberAdded { address });
        }

        // Creates a new savings group, caller becomes first member
        // Returns the id of the created group
        fn create_group(ref self: ContractState, max_members: u8) -> u64 {
            let caller = get_caller_address();

            // Member validation
            assert(self.is_user_registered(caller), RegistrationErrors::USER_NOT_FOUND);
            assert(self.is_kyc_valid(caller), KYCErrors::INVALID_KYC_STATUS);

            // Require at least two members in the group
            assert(max_members > 1, GroupErrors::INVALID_GROUP_SIZE);

            let group_id = self._new_group_id();

            // Store group parameters
            self
                .groups
                .write(
                    group_id,
                    SavingsGroup {
                        id: group_id,
                        creator: caller,
                        max_members,
                        member_count: 1_u8,
                        is_active: true,
                    },
                );

            // Add caller as member of the group
            self.group_members.write((group_id, caller), true);

            // Emit group created event
            self.emit(GroupCreated { group_id, creator: caller, max_members });

            group_id
        }

        // Join an existing active group
        fn join_group(ref self: ContractState, group_id: u64) {
            let caller = get_caller_address();

            // Member validation
            assert(self.is_user_registered(caller), RegistrationErrors::USER_NOT_FOUND);
            assert(self.is_kyc_valid(caller), KYCErrors::INVALID_KYC_STATUS);

            let group = self.groups.entry(group_id).read();

            // Group must be active
            assert(group.is_active, GroupErrors::GROUP_INACTIVE);

            // Caller must not already be a member
            assert(
                !self.group_members.entry((group_id, caller)).read(), GroupErrors::ALREADY_MEMBER,
            );

            // Group must not be full
            assert(group.member_count < group.max_members, GroupErrors::GROUP_FULL);

            // Update number of members in the group
            self.groups.entry(group_id).member_count.write(group.member_count + 1);

            // Mark caller as member of the group
            self.group_members.write((group_id, caller), true);

            // Emit member joined event
            self.emit(MemberJoined { group_id, member: caller });
        }

        fn get_asset_price(self: @ContractState, asset_id: felt252) -> u128 {
            // Retrieve the oracle dispatcher
            let oracle_dispatcher = IPragmaABIDispatcher {
                contract_address: self.oracle_address.read(),
            };

            let output: PragmaPricesResponse = oracle_dispatcher
                .get_data_median(DataType::SpotEntry(asset_id));

            return output.price;
        }
    }

    // Internal helper functions
    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn _validate_kyc_and_limits(self: @ContractState, user: ContractAddress, amount: u256) {
            // Check KYC validity
            assert(self.is_kyc_valid(user), KYCErrors::INVALID_KYC_STATUS);

            // Check transaction limits
            let kyc_data = self.user_kyc_data.read(user);
            let level_u8 = self._kyc_level_to_u8(kyc_data.level);

            // Check single transaction limit
            let single_limit = self.single_limits.read(level_u8);
            assert(amount <= single_limit, KYCErrors::SINGLE_TX_LIMIT_EXCEEDED);

            // Check daily limit
            let daily_limit = self.daily_limits.read(level_u8);
            let current_usage = self._get_daily_usage(user);
            assert(current_usage + amount <= daily_limit, KYCErrors::DAILY_LIMIT_EXCEEDED);
        }

        fn _get_daily_usage(self: @ContractState, user: ContractAddress) -> u256 {
            let current_time = get_block_timestamp();
            let last_reset = self.last_reset.read(user);

            // Reset if it's a new day (86400 seconds = 24 hours)
            if current_time > last_reset + 86400 {
                return 0;
            }

            self.daily_usage.read(user)
        }

        fn _record_daily_usage(ref self: ContractState, user: ContractAddress, amount: u256) {
            let current_time = get_block_timestamp();
            let last_reset = self.last_reset.read(user);

            if current_time > last_reset + 86400 {
                // Reset for new day
                self.daily_usage.write(user, amount);
                self.last_reset.write(user, current_time);
            } else {
                // Add to current day usage
                let current_usage = self.daily_usage.read(user);
                self.daily_usage.write(user, current_usage + amount);
            }
        }

        fn _kyc_level_to_u8(self: @ContractState, level: KycLevel) -> u8 {
            match level {
                KycLevel::None => 0,
                KycLevel::Basic => 1,
                KycLevel::Enhanced => 2,
                KycLevel::Premium => 3,
            }
        }

        fn _set_default_transaction_limits(ref self: ContractState) {
            // None level - very restricted
            self.daily_limits.write(0, 100_000_000_000_000_000); // 0.1 tokens
            self.single_limits.write(0, 50_000_000_000_000_000); // 0.05 tokens

            // Basic level - moderate limits
            self.daily_limits.write(1, 1000_000_000_000_000_000_000); // 1,000 tokens
            self.single_limits.write(1, 500_000_000_000_000_000_000); // 500 tokens

            // Enhanced level - higher limits
            self.daily_limits.write(2, 10000_000_000_000_000_000_000); // 10,000 tokens
            self.single_limits.write(2, 5000_000_000_000_000_000_000); // 5,000 tokens

            // Premium level - maximum limits
            self.daily_limits.write(3, 100000_000_000_000_000_000_000); // 100,000 tokens
            self.single_limits.write(3, 50000_000_000_000_000_000_000); // 50,000 tokens
        }


        fn _record_transfer_history(
            ref self: ContractState,
            transfer_id: u256,
            action: felt252,
            actor: ContractAddress,
            previous_status: TransferStatus,
            new_status: TransferStatus,
            details: felt252,
        ) {
            let current_time = get_block_timestamp();

            // Create history entry
            let history = TransferHistory {
                transfer_id,
                action,
                actor,
                timestamp: current_time,
                previous_status,
                new_status,
                details,
            };

            // Store in transfer history
            let history_count = self.transfer_history_count.read(transfer_id);
            self.transfer_history.write((transfer_id, history_count), history);
            self.transfer_history_count.write(transfer_id, history_count + 1);

            // Store in actor history
            let actor_count = self.actor_history_count.read(actor);
            self.actor_history.write((actor, actor_count), (transfer_id, history_count));
            self.actor_history_count.write(actor, actor_count + 1);

            // Store in action history
            let action_count = self.action_history_count.read(action);
            self.action_history.write((action, action_count), (transfer_id, history_count));
            self.action_history_count.write(action, action_count + 1);

            // Emit event
            self
                .emit(
                    TransferHistoryRecorded { transfer_id, action, actor, timestamp: current_time },
                );
        }

        // Generates and stores a new unique group ID for a savings group
        // Returns the newly generated group ID
        fn _new_group_id(ref self: ContractState) -> u64 {
            let group_id = self.group_count.read();

            self.group_count.write(group_id + 1);

            group_id
        }
    }

    // Multi-currency functions
    #[generate_trait]
    impl MultiCurrencyFunctions of MultiCurrencyFunctionsTrait {
        // Registers a new supported currency
        // Only callable by admin
        fn register_currency(ref self: ContractState, currency: felt252) {
            let caller = get_caller_address();
            // Validate caller is admin
            assert(caller == self.admin.read(), ERC20Errors::NotAdmin); // "Only admin" in felt252

            // Register the currency
            self.supported_currencies.write(currency, true);
        }

        // Converts tokens from one currency to another
        // Returns the amount of tokens received in the target currency
        fn convert_currency(
            ref self: ContractState,
            user: ContractAddress,
            from_currency: felt252,
            to_currency: felt252,
            amount: u256,
        ) -> u256 {
            // Validate currencies are supported
            assert(
                self.supported_currencies.read(from_currency),
                0x556e737570706f727465645f736f75726365 // "Unsupported_source" in felt252
            );
            assert(
                self.supported_currencies.read(to_currency),
                0x556e737570706f727465645f746172676574 // "Unsupported_target" in felt252
            );

            // Verify user has sufficient balance in source currency
            let from_balance = self.currency_balances.read((user, from_currency));
            assert(from_balance >= amount, ERC20Errors::INSUFFICIENT_BALANCE);

            // Get exchange rate from oracle
            let oracle = IOracleDispatcher { contract_address: self.oracle_address.read() };
            let rate: u256 = oracle.get_rate(from_currency, to_currency);

            // Calculate converted amount using fixed-point arithmetic
            let converted = amount * rate / FIXED_POINT_SCALER;

            // Update currency balances
            self.currency_balances.write((user, from_currency), from_balance - amount);
            let to_balance = self.currency_balances.read((user, to_currency));
            self.currency_balances.write((user, to_currency), to_balance + converted);

            // Emit conversion event
            self
                .emit(
                    TokenConverted {
                        user, from_currency, to_currency, amount_in: amount, amount_out: converted,
                    },
                );

            converted
        }
    }

    // Oracle interface for retrieving exchange rates
    #[starknet::interface]
    trait IOracle<T> {
        // Gets the exchange rate between two currencies
        // Returns the rate as a fixed-point number (with FIXED_POINT_SCALER precision)
        fn get_rate(self: @T, from: felt252, to: felt252) -> u256;
    }

    // Mock implementation of OracleInterface for testing
    #[starknet::contract]
    mod MockOracle {
        #[storage]
        struct Storage {}

        #[generate_trait]
        impl OracleInterface of IOracle {
            // Mock implementation that returns a 1:1 conversion rate
            fn get_rate(self: @ContractState, from: felt252, to: felt252) -> u256 {
                // Mock rate for testing purposes
                1_000_000_000_000_000_000 // Example: 1:1 conversion rate
            }
        }
    }
}
