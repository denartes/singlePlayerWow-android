package com.denartes.bygdoketernal.realm

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

enum class ComponentStatus {
    NOT_CONFIGURED,
    STARTING,
    RUNNING,
    STOPPED,
    FAILED
}

data class RealmState(
    val database: ComponentStatus = ComponentStatus.NOT_CONFIGURED,
    val authserver: ComponentStatus = ComponentStatus.NOT_CONFIGURED,
    val worldserver: ComponentStatus = ComponentStatus.NOT_CONFIGURED
) {
    val isRunning: Boolean
        get() = database == ComponentStatus.RUNNING &&
            authserver == ComponentStatus.RUNNING &&
            worldserver == ComponentStatus.RUNNING

    val isBusy: Boolean
        get() = database == ComponentStatus.STARTING ||
            authserver == ComponentStatus.STARTING ||
            worldserver == ComponentStatus.STARTING
}

/** In-process shared state between [RealmForegroundService] and the dashboard UI. */
object RealmRuntime {
    private const val MAX_LOG_LINES = 500

    private val _state = MutableStateFlow(RealmState())
    val state = _state.asStateFlow()

    private val _logLines = MutableStateFlow<List<String>>(emptyList())
    val logLines = _logLines.asStateFlow()

    fun updateState(transform: (RealmState) -> RealmState) {
        _state.update(transform)
    }

    fun appendLog(line: String) {
        _logLines.update { (it + line).takeLast(MAX_LOG_LINES) }
    }
}
