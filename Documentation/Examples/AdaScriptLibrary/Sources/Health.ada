func remainingHealth(current, damage) {
    if (damage >= current) { return 0; }
    return current - damage;
}
