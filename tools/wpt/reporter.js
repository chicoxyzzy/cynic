// Register before loading fixture dependencies or fixture source. Keep upstream
// numeric status values so failed/precondition/timeout results remain distinct.
(function () {
    const emit = print;
    const stringify = JSON.stringify;
    setup({output: false, explicit_done: true});

    add_result_callback(function (result) {
        emit('@@WPT@@' + stringify({
            type: 'result',
            name: result.name,
            status: result.status,
            message: result.message
        }));
    });

    add_completion_callback(function (_tests, status) {
        emit('@@WPT@@' + stringify({
            type: 'complete',
            status: status.status,
            message: status.message
        }));
    });
})();
