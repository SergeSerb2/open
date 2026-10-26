# Native foreground trace, before virtual-pointer isolation

Source `4c15a8b`; fork UUID `4C4C4432-5555-3144-A144-B678285BC5F4`.
The first Debug window receipt records native resignation/activation events
while its reveal card disappears. Those rows remain FAIL. The second window
run passes. This phase stopped at a suite boundary after the lead confirmed
that other agents and the user must continue to use the foreground. No Release
run occurred in this phase. The next phase isolates only the virtual pointer
and records/retries interrupted native-focus workflows.
