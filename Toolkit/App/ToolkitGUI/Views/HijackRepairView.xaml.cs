using ToolkitGUI.Services;

namespace ToolkitGUI.Views
{
    public partial class HijackRepairView : WorkflowViewBase
    {
        public HijackRepairView() => InitializeComponent();

        public void ApplyPendingNavigationContext()
        {
            // Reserved for symptom-flow navigation context; ensures cached view receives updates.
            _ = NavigationService.ConsumePendingContext();
        }
    }
}
