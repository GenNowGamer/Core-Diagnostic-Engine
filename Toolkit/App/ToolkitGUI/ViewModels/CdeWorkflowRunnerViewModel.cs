using System.Threading.Tasks;

namespace ToolkitGUI.ViewModels
{
    public sealed class CdeWorkflowRunnerViewModel : WorkflowViewModelBase
    {
        protected override bool ShowWorkflowExecutionWindow => true;

        public Task RunAsync(string scriptPath, string? parameters, string title, string description)
            => RunWorkflowAsync(scriptPath, parameters, title, description);
    }
}
